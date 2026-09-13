const express = require('express');
const { Pool } = require('pg');
const axios = require('axios');
const { exec } = require('child_process');
const fs = require('fs');

const app = express();
app.use(express.json());
app.use(express.urlencoded({ extended: true }));

const pool = new Pool({
  host: process.env.POSTGRES_HOST || 'postgres',
  port: process.env.POSTGRES_PORT || 5432,
  database: process.env.POSTGRES_DB || 'iam_database',
  user: process.env.POSTGRES_USER || 'iam_user',
  password: process.env.POSTGRES_PASSWORD || 'secretpassword',
});

const ROCKETCHAT_URL = process.env.ROCKETCHAT_URL || 'http://rocketchat:4000';
const GITEA_URL = process.env.GITEA_URL || 'http://gitea:3000';

let rcAuthHeaders = {};

async function authenticateRocketChat() {
  try {
    const res = await axios.post(`${ROCKETCHAT_URL}/api/v1/login`, {
      user: 'admin',
      password: 'AdminPassword123!'
    });
    if (res.data && res.data.data) {
      rcAuthHeaders = {
        'X-Auth-Token': res.data.data.authToken,
        'X-User-Id': res.data.data.userId,
        'Content-Type': 'application/json'
      };
      console.log('Successfully authenticated trade-bot with Rocket.Chat');
    }
  } catch (err) {
    console.error('Rocket.Chat authentication failed:', err.message);
  }
}

// 1. Handle trade request from #trades
app.post('/webhook/trade', async (req, res) => {
  const text = req.body.text || '';
  const username = req.body.user_name || 'unknown';

  const match = text.match(/!trade\s+(BUY|SELL)\s+(\d+)\s+([A-Z]+)/i);
  if (!match) {
    return res.json({ text: "Invalid format. Use: `!trade BUY <qty> <symbol>`" });
  }

  const [_, action, qty, symbol] = match;
  const tradeId = `TRD-${Date.now()}`;

  try {
    await pool.query(
      `INSERT INTO trades (trade_id, requester, symbol, quantity, status, pnl_usd) 
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [tradeId, username, symbol.toUpperCase(), parseInt(qty), 'PENDING', 0.00]
    );

    if (!rcAuthHeaders['X-Auth-Token']) await authenticateRocketChat();

    // Post alert to #trade-approvals
    await axios.post(`${ROCKETCHAT_URL}/api/v1/chat.postMessage`, {
      channel: '#trade-approvals',
      text: `🚨 **Trade Approval Required**\n**ID:** ${tradeId}\n**User:** ${username}\n**Order:** ${action} ${qty} ${symbol}\n\nTo approve: \`!approve ${tradeId}\``
    }, { headers: rcAuthHeaders });

    return res.json({ text: `Trade request submitted for approval. ID: \`${tradeId}\`` });
  } catch (err) {
    console.error(err);
    return res.json({ text: `Error processing trade: ${err.message}` });
  }
});

// 2. Handle trade approval from #trade-approvals
app.post('/webhook/approve', async (req, res) => {
  const text = req.body.text || '';
  const approver = req.body.user_name || 'unknown';

  const match = text.match(/!approve\s+(TRD-\d+)/i);
  if (!match) {
    return res.json({ text: "Invalid format. Use: `!approve <trade_id>`" });
  }

  const tradeId = match[1];

  try {
    const dbRes = await pool.query(`SELECT * FROM trades WHERE trade_id = $1`, [tradeId]);
    if (dbRes.rows.length === 0) {
      return res.json({ text: `Trade \`${tradeId}\` not found.` });
    }

    const trade = dbRes.rows[0];

    // Updated fetch path to query trading-org instead of giteaadmin
    const giteaRes = await axios.get(`${GITEA_URL}/api/v1/repos/trading-org/trade-scripts/raw/main/simulate_trade.py`);
    fs.writeFileSync('/tmp/simulate_trade.py', giteaRes.data);

    exec(`python3 /tmp/simulate_trade.py ${trade.trade_id} ${trade.symbol} ${trade.quantity}`, async (error, stdout) => {
      if (error) {
        return res.json({ text: `Execution error: ${error.message}` });
      }

      const result = JSON.parse(stdout);

      // Update Postgres with execution status, PnL, and approver username
      await pool.query(
        `UPDATE trades SET status = $1, pnl_usd = $2, approver = $3 WHERE trade_id = $4`,
        [result.status, result.pnl_usd, approver, tradeId]
      );

      if (!rcAuthHeaders['X-Auth-Token']) await authenticateRocketChat();

      // Report result back to #trades channel
      await axios.post(`${ROCKETCHAT_URL}/api/v1/chat.postMessage`, {
        channel: '#trades',
        text: `📈 **Trade Executed**\n**ID:** ${tradeId}\n**Symbol:** ${trade.symbol}\n**Status:** ${result.status}\n**P&L:** $${result.pnl_usd}\n**Approved By:** ${approver}`
      }, { headers: rcAuthHeaders });

      return res.json({ text: `Trade \`${tradeId}\` approved and executed successfully.` });
    });
  } catch (err) {
    console.error(err);
    return res.json({ text: `Approval processing error: ${err.message}` });
  }
});

app.listen(5000, async () => {
  console.log('Trade Bot service listening on port 5000');
  await authenticateRocketChat();
});

app.post('/webhook/joiner', async (req, res) => {
  const { text = '', channel_name = '' } = req.body;

  if (channel_name !== 'hr') {
    return res.json({ text: "⚠️ Access Denied: Command restricted to #hr channel." });
  }

  const parts = text.trim().split(/\s+/);
  if (parts.length < 4) {
    return res.json({ text: "Usage: `!joiner <FirstName> <LastName> <developer|trader|manager|human_resources>`" });
  }

  const [, firstName, lastName, roleName] = parts;

  // Map role names to midPoint Role OIDs
  const roleOids = {
    developer: '10000000-0000-0000-0000-000000000001',
    trader: '10000000-0000-0000-0000-000000000002',
    manager: '10000000-0000-0000-0000-000000000003',
    human_resources: '10000000-0000-0000-0000-000000000004'
  };

  const roleOid = roleOids[roleName.toLowerCase()];
  if (!roleOid) {
    return res.json({ text: `Invalid role. Choose from: ${Object.keys(roleOids).join(', ')}` });
  }

  // Construct minimal midPoint User XML
  const userXml = `
    <user xmlns="http://midpoint.evolveum.com/xml/ns/public/common/common-3" xmlns:c="http://midpoint.evolveum.com/xml/ns/public/common/common-3">
      <givenName>${firstName}</givenName>
      <familyName>${lastName}</familyName>
      <assignment>
        <targetRef oid="${roleOid}" type="c:RoleType"/>
      </assignment>
    </user>
  `;

  // Submit directly to midPoint REST API
  try {
    const auth = Buffer.from('administrator:5ecr3t').toString('base64'); // midPoint admin credentials
    await axios.post('http://midpoint:8080/midpoint/ws/rest/users', userXml, {
      headers: {
        'Content-Type': 'application/xml',
        'Authorization': `Basic ${auth}`
      }
    });

    return res.json({
      text: `✅ **Joiner Process Started in midPoint**\n**User:** ${firstName} ${lastName}\n**Role:** ${roleName}\nmidPoint is auto-generating identity details and provisioning target accounts via Resource Inducements.`
    });
  } catch (err) {
    return res.json({ text: `❌ midPoint Processing Failed: ${err.message}` });
  }
});