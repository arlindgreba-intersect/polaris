/**
 * Polaris — Roman III LCOE Model V6 (Case 4, Monthly Haul, 2026-04)
 * ==================================================================
 * File: v6_polaris_consolidated.gs
 *
 * Single consolidated Apps Script for all tab ingestions.
 * Install this ONE file in Extensions → Apps Script.
 * No other .gs files needed.
 *
 * TABS COVERED
 * ─────────────────────────────────────────────────────────────────
 *  Tab                Function to call             BQ table
 *  ─────────────────  ──────────────────────────   ─────────────────────────
 *  Inputs             v6_pushInputsTab()           v6_raw_inputs_tab
 *  CAPEX_Tool         v6_pushCapexTool()           v6_raw_capex_tool
 *  Opex_Tool          v6_pushOpexTool()            v6_raw_opex_tool
 *  20yrLCOECalc       v6_pushLcoeCalcs()           v6_raw_lcoe_calcs
 *  Pro Formas x4      v6_pushProFormaSummary()     v6_raw_pro_forma_summary
 *  Output_Summary     v6_pushOutputSummary()       v6_raw_output_summary
 *  Sign Off Sheet     v6_pushSignOffSheet()        v6_raw_sign_off_sheet
 *
 * PUSH ALL excludes Pro Forma (push separately if needed).
 *
 * V6 STRUCTURAL NOTES (vs V4)
 * ─────────────────────────────────────────────────────────────────
 *  - Tab renamed: "20yrLCOE Calcs" → "20yrLCOECalc"
 *  - Tab name:    " Sign Off Sheet" (leading space — handled)
 *  - Inputs tab:  sections run to row 368 (Gas + DTC specific opex at bottom)
 *  - CAPEX_Tool:  Solar R5–R38, Wind R40–R73, BESS R75–R108, Gas R110–R143, DTC R145–R177
 *  - Opex_Tool:   Flags R1–R43, Solar R44–R117, Wind R118–R194, BESS R195–R269,
 *                 Gas R270–R327, DTC R328–R355
 *  - Monthly time horizon: Dec 2023 – Dec 2071 (579 columns)
 *  - All BQ tables and GCS paths prefixed "v6_"
 *  - No OPEX Variances tab in V6
 *
 * INSTALL
 * ─────────────────────────────────────────────────────────────────
 *  1. Open the V6 Google Sheet → Extensions → Apps Script
 *  2. Delete any existing .gs files
 *  3. Rename "Code.gs" to "v6_polaris_consolidated" → paste this file → Save
 *  4. Replace appsscript.json with the one supplied (oauthScopes block)
 *  5. Link GCP project: Project Settings → GCP Project → enter project number
 *  6. Run v6_checkSetup() to verify all tabs found
 *  7. Set devMode: false in V6_CONFIG when ready to go live
 *
 * REQUIRED appsscript.json SCOPES
 * ─────────────────────────────────────────────────────────────────
 *  https://www.googleapis.com/auth/spreadsheets
 *  https://www.googleapis.com/auth/devstorage.read_write
 *  https://www.googleapis.com/auth/script.external_request
 *  https://www.googleapis.com/auth/drive
 *  https://www.googleapis.com/auth/userinfo.email
 *  https://www.googleapis.com/auth/bigquery
 *  https://www.googleapis.com/auth/script.container.ui
 */


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 1 — GLOBAL CONFIG
// ═══════════════════════════════════════════════════════════════════════════════

const V6_CONFIG = {

  devMode: false,   // ← set false for live pushes to GCS + BQ

  gcsBucket:   'ag_test_raw_input_from_lcoe_model',
  gcsPrefix:   'raw/v6',
  bqProjectId: 'sandbox-lakehouse',
  bqDatasetId: 'polaris_raw',
  bqLocation:  'us-south1',

  projectId:  'Roman III',
  modelName:  'Roman III LCOE Model V6 - Case 4 - Monthly Haul - 2026-04',

  // BQ table names — all prefixed v6_
  tables: {
    inputs:        'v6_raw_inputs_tab',
    capex:         'v6_raw_capex_tool',
    opex:          'v6_raw_opex_tool',
    lcoeCalcs:     'v6_raw_lcoe_calcs',
    proForma:      'v6_raw_pro_forma_summary',
    outputSummary: 'v6_raw_output_summary',
    signOff:       'v6_raw_sign_off_sheet',
  },

  // Tab names exactly as they appear in the V6 sheet
  tabs: {
    inputs:        'Inputs',
    capex:         'CAPEX_Tool',
    opex:          'Opex_Tool',
    lcoeCalcs:     '20yrLCOECalc',
    outputSummary: 'Output_Summary',
    signOff:       ' Sign Off Sheet',   // leading space intentional
    solarPF:       'Solar_Pro_Forma',
    windPF:        'Wind_Pro_Forma',
    bessPF:        'BESS_Pro_Forma',
    gasPF:         'Gas_Pro_Forma',
  },

  // ── Inputs tab ──
  inputs: {
    techCols: { Solar: 5, Wind: 6, Gas: 7, BESS: 8, DTC: 9 },
    sections: [
      { name: 'LCOE Drivers',                  start: 3,   end: 10  },
      { name: 'Dates',                          start: 13,  end: 21  },
      { name: 'Capacities & Performance',       start: 23,  end: 47  },
      { name: 'Tax Attributes',                 start: 49,  end: 97  },
      { name: 'Underwriting & Financing Fees',  start: 99,  end: 103 },
      { name: 'Contingency Adders',             start: 105, end: 107 },
      { name: 'CAPEX',                          start: 109, end: 152 },
      { name: 'OPEX',                           start: 154, end: 215 },
      { name: 'Other Expenses',                 start: 216, end: 336 },
      { name: 'Gas-Specific OPEX',              start: 338, end: 356 },
      { name: 'DTC-Specific OPEX',              start: 358, end: 368 },
    ],
    skipRows: new Set([
      1, 2, 3, 5, 11, 12, 13, 22, 23, 33, 49, 69, 87, 95, 99, 105,
      109, 118, 129, 131, 154, 156, 157, 162, 168, 178, 181, 184,
      216, 338, 341, 346, 358,
    ]),
  },

  // ── CAPEX_Tool section boundaries (row numbers, inclusive) ──
  capex: {
    monthlyStartCol: 5,   // col E = first date column (1-based)
    techSections: {
      Solar: { start: 5,   end: 38  },
      Wind:  { start: 40,  end: 73  },
      BESS:  { start: 75,  end: 108 },
      Gas:   { start: 110, end: 143 },
      DTC:   { start: 145, end: 177 },
    },
  },

  // ── Opex_Tool section boundaries ──
  opex: {
    monthlyStartCol: 7,   // col G = first date column (1-based)
    techSections: {
      Flags: { start: 1,   end: 43  },
      Solar: { start: 44,  end: 117 },
      Wind:  { start: 118, end: 194 },
      BESS:  { start: 195, end: 269 },
      Gas:   { start: 270, end: 327 },
      DTC:   { start: 328, end: 355 },
    },
  },

  // ── 20yrLCOECalc ──
  lcoeCalcs: {
    yearStartCol: 7,    // col G = first year column (1-based)
    techBlocks: [
      {
        technology: 'Facility', lcoeRow: 5,
        metricRows: [
          { row: 6,  metric: 'DTC_Consumption' },
          { row: 7,  metric: 'Capex' },
          { row: 8,  metric: 'Opex' },
          { row: 9,  metric: 'Credit_Monetization' },
          { row: 10, metric: 'Depreciation' },
        ],
      },
      {
        technology: 'Solar', lcoeRow: 15,
        metricRows: [
          { row: 16, metric: 'Generation' },
          { row: 17, metric: 'Capex' },
          { row: 18, metric: 'Opex' },
          { row: 19, metric: 'Credit_Monetization' },
          { row: 20, metric: 'Depreciation' },
        ],
      },
      {
        technology: 'Wind', lcoeRow: 25,
        metricRows: [
          { row: 26, metric: 'Generation' },
          { row: 27, metric: 'Capex' },
          { row: 28, metric: 'Opex' },
          { row: 29, metric: 'Credit_Monetization' },
          { row: 30, metric: 'Depreciation' },
        ],
      },
      {
        technology: 'Gas', lcoeRow: 35,
        metricRows: [
          { row: 36, metric: 'Capacity' },
          { row: 37, metric: 'Capex' },
          { row: 38, metric: 'Opex_ex_Fuel' },
          { row: 39, metric: 'Credit_Monetization' },
          { row: 40, metric: 'Depreciation' },
          { row: 42, metric: 'Fuel_Opex' },
        ],
      },
      {
        technology: 'BESS', lcoeRow: 45,
        metricRows: [
          { row: 46, metric: 'Capacity' },
          { row: 47, metric: 'Capex' },
          { row: 48, metric: 'Opex' },
          { row: 49, metric: 'Credit_Monetization' },
          { row: 50, metric: 'Depreciation' },
        ],
      },
    ],
    // Known values for validation — update when model version changes
    expectedLcoe: {
      Facility: 76.665,
      Solar:    29.925,
      Wind:     26.917,
      Gas:      15.856,
      BESS:     2.315,
    },
  },

  // ── Pro Forma tabs ──
  proForma: {
    tabs: [
      { tabKey: 'solarPF', technology: 'Solar' },
      { tabKey: 'windPF',  technology: 'Wind'  },
      { tabKey: 'bessPF',  technology: 'BESS'  },
      { tabKey: 'gasPF',   technology: 'Gas'   },
    ],
    summaryStartRow: 3,
    summaryEndRow:   13,
    labelCol: 4,   // col D
    valueCol: 5,   // col E
  },
};


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 2 — MENU
// ═══════════════════════════════════════════════════════════════════════════════

function onOpen() {
  const mode = V6_CONFIG.devMode ? ' (DEV)' : ' (LIVE)';
  SpreadsheetApp.getUi()
    .createMenu('Polaris V6' + mode)
    .addItem('🚀 Push ALL tabs → BQ',        'v6_pushAll')
    .addSeparator()
    .addItem('Push Inputs Tab → BQ',         'v6_pushInputsTab')
    .addItem('Push CAPEX Tool → BQ',         'v6_pushCapexTool')
    .addItem('Push Opex Tool → BQ',          'v6_pushOpexTool')
    .addItem('Push 20yr LCOE Calcs → BQ',    'v6_pushLcoeCalcs')
    .addItem('Push Pro Forma Summary → BQ',  'v6_pushProFormaSummary')
    .addItem('Push Output Summary → BQ',     'v6_pushOutputSummary')
    .addItem('Push Sign Off Sheet → BQ',     'v6_pushSignOffSheet')
    .addSeparator()
    .addItem('Check all tab setup',          'v6_checkSetup')
    .addToUi();
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 3 — SHARED DIALOG BUILDER
// ═══════════════════════════════════════════════════════════════════════════════

function _v6_showPushDialog(title, subtitle, infoHtml, callbackFn, lastPush, height) {
  const lastPushHtml = lastPush
    ? '<div class="last-push">Last push: <strong>' + lastPush + '</strong></div>'
    : '<div class="last-push no-data">No previous pushes found in BQ.</div>';

  const modeBadge = V6_CONFIG.devMode
    ? '<span class="badge dev">DEV MODE — no writes</span>'
    : '<span class="badge live">LIVE — writes to GCS + BQ</span>';

  const btnClass = V6_CONFIG.devMode ? 'btn-push dev' : 'btn-push';
  const btnText  = V6_CONFIG.devMode ? 'Preview (DEV)' : 'Push to GCS + BQ';

  const css =
    '* { box-sizing:border-box; margin:0; padding:0; }' +
    'body { font-family:"Google Sans",Arial,sans-serif; font-size:13px; color:#202124; padding:20px; width:380px; }' +
    'h2 { font-size:16px; font-weight:500; margin-bottom:4px; color:#1a73e8; }' +
    '.subtitle { font-size:11px; color:#5f6368; margin-bottom:14px; }' +
    '.last-push { background:#f1f8e9; border-left:3px solid #4caf50; padding:8px 10px; border-radius:3px; font-size:11px; color:#33691e; margin-bottom:12px; }' +
    '.last-push.no-data { background:#fafafa; border-left-color:#bdbdbd; color:#757575; }' +
    '.badge { display:inline-block; padding:2px 10px; border-radius:10px; font-size:11px; font-weight:600; margin-bottom:14px; }' +
    '.badge.dev { background:#fff3e0; color:#e65100; }' +
    '.badge.live { background:#e8f5e9; color:#1b5e20; }' +
    'label { display:block; font-size:11px; font-weight:600; color:#5f6368; text-transform:uppercase; letter-spacing:.05em; margin-bottom:4px; margin-top:14px; }' +
    'input[type=text], select, textarea { width:100%; padding:8px 10px; border:1px solid #dadce0; border-radius:4px; font-size:13px; color:#202124; outline:none; font-family:inherit; }' +
    'input:focus, select:focus, textarea:focus { border-color:#1a73e8; }' +
    'textarea { resize:vertical; min-height:56px; }' +
    '.info-box { background:#f8f9fa; border:1px solid #e8eaed; border-radius:4px; padding:10px 12px; font-size:11px; color:#5f6368; margin-top:14px; line-height:1.7; }' +
    '.info-box strong { color:#202124; }' +
    '.buttons { display:flex; justify-content:flex-end; gap:8px; margin-top:20px; }' +
    'button { padding:8px 20px; border-radius:4px; font-size:13px; font-weight:500; cursor:pointer; border:none; }' +
    '.btn-cancel { background:#fff; color:#1a73e8; border:1px solid #dadce0; }' +
    '.btn-push { background:#1a73e8; color:#fff; }' +
    '.btn-push.dev { background:#e65100; }' +
    '.err { color:#d93025; font-size:11px; margin-top:4px; display:none; }';

  const body =
    '<h2>' + title + '</h2>' +
    '<div class="subtitle">' + subtitle + '</div>' +
    lastPushHtml + modeBadge +
    '<label>Run label</label>' +
    '<input type="text" id="lbl" placeholder="e.g. budget-2026-v1, post-rr-approval" />' +
    '<div class="err" id="lblErr">Run label is required.</div>' +
    '<label>Run type</label>' +
    '<select id="rtype">' +
    '<option value="budget">Budget</option>' +
    '<option value="current_forecast">Current Forecast</option>' +
    '<option value="proposed_forecast">Proposed Forecast</option>' +
    '<option value="test">Test</option>' +
    '</select>' +
    '<label>Notes <span style="font-weight:400;text-transform:none">(optional)</span></label>' +
    '<textarea id="notes" placeholder="e.g. Post BOD approval"></textarea>' +
    '<div class="info-box">' + infoHtml + '</div>' +
    '<div class="buttons">' +
    '<button class="btn-cancel" onclick="google.script.host.close()">Cancel</button>' +
    '<button class="' + btnClass + '" id="pb" onclick="go()">' + btnText + '</button>' +
    '</div>';

  const js =
    'document.getElementById("lbl").focus();' +
    'document.addEventListener("keydown",function(e){' +
    '  if(e.key==="Enter"&&e.target.tagName!=="TEXTAREA")go();' +
    '  if(e.key==="Escape")google.script.host.close();' +
    '});' +
    'function go(){' +
    '  var l=document.getElementById("lbl").value.trim();' +
    '  var er=document.getElementById("lblErr");' +
    '  if(!l){er.style.display="block";document.getElementById("lbl").focus();return;}' +
    '  er.style.display="none";' +
    '  var pb=document.getElementById("pb");' +
    '  pb.disabled=true; pb.textContent="Pushing...";' +
    '  google.script.run' +
    '    .withSuccessHandler(function(){google.script.host.close();})' +
    '    .withFailureHandler(function(e){pb.disabled=false;pb.textContent="Retry";alert("Error: "+e.message);})' +
    '    .' + callbackFn + '(l,document.getElementById("rtype").value,document.getElementById("notes").value.trim());' +
    '}';

  const html = '<!DOCTYPE html><html><head><style>' + css + '</style></head><body>' +
               body + '<script>' + js + '</script></body></html>';

  SpreadsheetApp.getUi().showModalDialog(
    HtmlService.createHtmlOutput(html).setWidth(440).setHeight(height || 560),
    title
  );
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 4 — SHARED UTILITIES
// ═══════════════════════════════════════════════════════════════════════════════

function _v6_runId(label) {
  const ts   = Utilities.formatDate(new Date(), 'UTC', 'yyyyMMdd-HHmmss');
  const hash = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, ts + label);
  const hex  = _v6_hexStr(hash).slice(0, 8);
  return 'run-' + ts + '-' + label.slice(0, 20) + '-' + hex;
}

function _v6_snapshotId(slug, records) {
  const skip = new Set([
    'run_id','run_type','run_label','run_notes','snapshot_id',
    'pushed_by','pushed_at','workbook_name','workbook_url',
    'source_row','project_id','model_name','source_tab','source_table',
  ]);
  const canonical = records
    .map(r => Object.entries(r).filter(([k]) => !skip.has(k))
               .map(([k, v]) => k + '=' + (v === null ? '' : String(v))).sort().join('|'))
    .sort().join('\n');
  const bytes = Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, canonical);
  const ts    = Utilities.formatDate(new Date(), 'UTC', 'yyyyMMdd-HHmmss');
  return slug + '-' + ts + '-' + _v6_hexStr(bytes).slice(0, 12);
}

function _v6_hexStr(bytes) {
  return bytes.map(b => { const v = (b < 0 ? b + 256 : b).toString(16); return v.length === 1 ? '0' + v : v; }).join('');
}

function _v6_fmtDate(val) {
  if (!(val instanceof Date)) return String(val).substring(0, 10);
  return Utilities.formatDate(val, 'UTC', 'yyyy-MM-dd');
}

function _v6_sanitizeKey(str) {
  return String(str).toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').substring(0, 60);
}

function _v6_fmtVal(val) {
  if (typeof val === 'number') return val * 1.0;
  if (val instanceof Date) return _v6_fmtDate(val);
  if (val === null || val === undefined || val === '' || val === 'N/A') return null;
  return val;
}

function _v6_base(ss, sourceTab, sourceTable, runId, runType, label, notes, pushedAt, pushedBy) {
  return {
    run_id:        runId,
    run_type:      runType,
    run_label:     label,
    run_notes:     notes || null,
    snapshot_id:   null,
    project_id:    V6_CONFIG.projectId,
    model_name:    V6_CONFIG.modelName,
    source_tab:    sourceTab,
    source_table:  sourceTable,
    pushed_by:     pushedBy,
    pushed_at:     pushedAt,
    workbook_name: ss.getName(),
    workbook_url:  ss.getUrl(),
  };
}

function _v6_uploadGcs(bucket, objectPath, jsonl) {
  const url = 'https://storage.googleapis.com/upload/storage/v1/b/' +
              encodeURIComponent(bucket) + '/o?uploadType=media&name=' +
              encodeURIComponent(objectPath);
  const resp = UrlFetchApp.fetch(url, {
    method: 'post', contentType: 'application/x-ndjson', payload: jsonl,
    headers: { 'Authorization': 'Bearer ' + ScriptApp.getOAuthToken() },
    muteHttpExceptions: true,
  });
  return { ok: resp.getResponseCode() >= 200 && resp.getResponseCode() < 300,
           code: resp.getResponseCode(), body: resp.getContentText() };
}

function _v6_loadBq(gcsUri, tableId) {
  const proj = V6_CONFIG.bqProjectId, ds = V6_CONFIG.bqDatasetId;

  // FMA-83: fetch existing table schema and pass it explicitly to avoid autodetect
  // inferring INTEGER for whole-number values that should be FLOAT64.
  const tblUrl = 'https://bigquery.googleapis.com/bigquery/v2/projects/' + proj +
                 '/datasets/' + ds + '/tables/' + tableId;
  const tblResp = UrlFetchApp.fetch(tblUrl, {
    method: 'get',
    headers: { 'Authorization': 'Bearer ' + ScriptApp.getOAuthToken() },
    muteHttpExceptions: true,
  });
  if (tblResp.getResponseCode() !== 200) {
    throw new Error('BQ tables.get HTTP ' + tblResp.getResponseCode() + ': ' +
                    tblResp.getContentText().substring(0, 300));
  }
  const existingSchema = JSON.parse(tblResp.getContentText()).schema;

  const url  = 'https://bigquery.googleapis.com/bigquery/v2/projects/' + proj + '/jobs';
  const resp = UrlFetchApp.fetch(url, {
    method: 'post', contentType: 'application/json',
    payload: JSON.stringify({
      configuration: { load: {
        sourceUris: [gcsUri],
        destinationTable: { projectId: proj, datasetId: ds, tableId },
        sourceFormat: 'NEWLINE_DELIMITED_JSON',
        autodetect: false,
        schema: existingSchema,
        writeDisposition: 'WRITE_APPEND',
        ignoreUnknownValues: true, maxBadRecords: 100,
        schemaUpdateOptions: ['ALLOW_FIELD_ADDITION'],
      }},
    }),
    headers: { 'Authorization': 'Bearer ' + ScriptApp.getOAuthToken() },
    muteHttpExceptions: true,
  });
  const code = resp.getResponseCode();
  const body = resp.getContentText();
  if (code === 200) return JSON.parse(body).jobReference.jobId;
  throw new Error('BQ API HTTP ' + code + ': ' + body.substring(0, 300));
}

function _v6_finalise(records, slug, tableId, runId, snapDate) {
  const snapshotId = _v6_snapshotId(slug, records);
  records.forEach(r => { r.snapshot_id = snapshotId; });

  const jsonl    = records.map(r => JSON.stringify(r)).join('\n') + '\n';
  const fileName = runId + '_' + slug + '-' + snapshotId.slice(-12) + '.jsonl';
  const gcsPath  = V6_CONFIG.gcsPrefix + '/' + slug + '/snapshot_date=' + snapDate + '/' + fileName;
  const gcsUri   = 'gs://' + V6_CONFIG.gcsBucket + '/' + gcsPath;

  if (V6_CONFIG.devMode) {
    Logger.log('[DEV] slug=' + slug + ' records=' + records.length + ' gcs=' + gcsUri);
    Logger.log('[DEV] Sample: ' + JSON.stringify(records[0]).substring(0, 300));
    return { snapshotId, gcsUri, bqJobId: null, bqError: null };
  }

  const gcsResult = _v6_uploadGcs(V6_CONFIG.gcsBucket, gcsPath, jsonl);
  if (!gcsResult.ok) throw new Error('GCS upload failed HTTP ' + gcsResult.code + ': ' + gcsResult.body.substring(0, 200));

  let bqJobId = null, bqError = null;
  try { bqJobId = _v6_loadBq(gcsUri, tableId); }
  catch(e) { bqError = e.message; }

  return { snapshotId, gcsUri, bqJobId, bqError };
}

function _v6_lastPush(tableId) {
  try {
    const q = 'SELECT pushed_by, pushed_at, run_label FROM `' +
              V6_CONFIG.bqProjectId + '.' + V6_CONFIG.bqDatasetId + '.' + tableId +
              '` ORDER BY pushed_at DESC LIMIT 1';
    const url = 'https://bigquery.googleapis.com/bigquery/v2/projects/' + V6_CONFIG.bqProjectId + '/queries';
    const resp = UrlFetchApp.fetch(url, {
      method: 'post', contentType: 'application/json',
      payload: JSON.stringify({ query: q, useLegacySql: false, timeoutMs: 5000, location: V6_CONFIG.bqLocation }),
      headers: { 'Authorization': 'Bearer ' + ScriptApp.getOAuthToken() },
      muteHttpExceptions: true,
    });
    if (resp.getResponseCode() !== 200) return null;
    const data = JSON.parse(resp.getContentText());
    if (!data.rows || !data.rows.length) return null;
    const f = data.rows[0].f;
    const d = new Date(parseFloat(f[1].v) * 1000);
    return Utilities.formatDate(d, Session.getScriptTimeZone(), "MMM d, yyyy 'at' h:mm a z") +
           ' by ' + f[0].v + ' (' + f[2].v + ')';
  } catch(e) { return null; }
}

function _v6_alert(title, runId, lines, pushedAt, pushedBy) {
  const t = Utilities.formatDate(new Date(pushedAt), Session.getScriptTimeZone(), "MMM d, yyyy 'at' h:mm a z");
  SpreadsheetApp.getUi().alert(
    title,
    'Run ID: ' + runId + '\n\n' + lines.join('\n') + '\n\nPushed at: ' + t + '\nPushed by: ' + pushedBy + '\n\n' +
    (V6_CONFIG.devMode ? 'DEV mode — check Execution Log. Set devMode:false to go live.' : 'Written to GCS + appended to BQ.'),
    SpreadsheetApp.getUi().ButtonSet.OK
  );
}

function _v6_monthHeaders(headerRow, startCol) {
  const headers = [];
  for (let c = startCol - 1; c < headerRow.length; c++) {
    const v = headerRow[c];
    if (v instanceof Date) {
      headers.push({ idx: c, key: 'period_' + Utilities.formatDate(v, 'UTC', 'yyyy_MM_dd') });
    } else if (v !== null && v !== undefined && String(v).trim() !== '') {
      headers.push({ idx: c, key: _v6_sanitizeKey(String(v)) });
    }
  }
  return headers;
}

function _v6_techFromRow(rowNum, techSections) {
  for (const [tech, bounds] of Object.entries(techSections)) {
    if (rowNum >= bounds.start && rowNum <= bounds.end) return tech;
  }
  return null;
}

function _v6_sectionFromRow(rowNum, sections) {
  for (const sec of sections) {
    if (rowNum >= sec.start && rowNum <= sec.end) return sec.name;
  }
  return 'Unknown';
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 5 — INPUTS TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushInputsTab() {
  _v6_showPushDialog(
    'Polaris V6 — Push Inputs Tab',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> Inputs &nbsp;|&nbsp; <strong>Rows:</strong> 3–368<br>' +
    '<strong>Sections:</strong> LCOE Drivers, Dates, Capacities, Tax, Underwriting, Contingency, CAPEX, OPEX, Other Expenses, Gas-Specific, DTC-Specific<br>' +
    '<strong>Format:</strong> Long — 1 row per input per technology (×5 techs)<br>' +
    '<strong>KILL rows:</strong> captured with is_kill=true',
    'v6_executeInputsPush', _v6_lastPush(V6_CONFIG.tables.inputs), 580
  );
}

function v6_executeInputsPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processInputs(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('Inputs Tab: ' + result.rowCount + ' records (long format)');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Sections: ' + JSON.stringify(result.sectionCounts));
    lines.push('KILL rows: ' + result.killCount);
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ error: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ Inputs Tab pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processInputs(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const cfg   = V6_CONFIG.inputs;
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.inputs);
  if (!sheet) throw new Error('Tab not found: ' + V6_CONFIG.tabs.inputs);

  const lastRow   = sheet.getLastRow();
  const allValues = sheet.getRange(1, 1, lastRow, 9).getValues();
  const records   = [];
  const sectionCounts = {};
  let killCount = 0;

  for (let ri = 0; ri < allValues.length; ri++) {
    const row       = allValues[ri];
    const sourceRow = ri + 1;
    if (!row.some(v => v !== null && v !== undefined && String(v).trim() !== '')) continue;
    if (cfg.skipRows.has(sourceRow)) continue;

    const colD = String(row[3] || '').trim();
    if (!colD) continue;

    const colA    = String(row[0] || '').trim();
    const isKill  = colA.toUpperCase().startsWith('KILL');
    const section = _v6_sectionFromRow(sourceRow, cfg.sections);
    sectionCounts[section] = (sectionCounts[section] || 0) + 1;
    if (isKill) killCount++;

    const rowNotes    = String(row[1] || '').trim() || null;
    const lineItemNum = (row[2] !== null && row[2] !== '' && !isNaN(parseFloat(String(row[2])))) ?
                        parseFloat(String(row[2])) : null;
    const dataOwner   = isKill ? (colA.replace(/^KILL\s*[-–]?\s*/i, '').trim() || 'KILL') : (colA || null);

    let rowType = 'input';
    if (isKill) rowType = 'kill';
    else if (['Year 1 Rate','Unit','Annual Escalation','Hardcode Override = 0',
               'Start Date','End Date','Fixed Amount=1; Monthly=0',
               'Step-up Year','Step-up Percentage'].includes(colD)) rowType = 'sub_parameter';
    else if (['Useful Life Expense','Fixed-term Expense','Expense'].includes(colD)) rowType = 'line_item_header';

    for (const [tech, colIdx] of Object.entries(cfg.techCols)) {
      const raw = row[colIdx - 1];
      let valueRaw = null, valueNum = null, valueDate = null;
      if (raw !== null && raw !== undefined && String(raw).trim() !== '' && String(raw).trim().toUpperCase() !== 'N/A') {
        if (raw instanceof Date) {
          valueRaw = _v6_fmtDate(raw);
          valueDate = valueRaw;
        } else {
          const s = String(raw).trim();
          valueRaw = s;
          const n = parseFloat(s);
          if (!isNaN(n)) valueNum = n;
        }
      }
      const rec = Object.assign(_v6_base(ss, V6_CONFIG.tabs.inputs, V6_CONFIG.tables.inputs,
                    runId, runType, label, notes, pushedAt, pushedBy), {
        source_row: sourceRow, section, input_name: colD, data_owner: dataOwner,
        notes: rowNotes, is_kill: isKill, row_type: rowType, line_item_num: lineItemNum,
        technology: tech, value_raw: valueRaw, value_num: valueNum, value_date: valueDate,
      });
      records.push(rec);
    }
  }
  if (!records.length) throw new Error('Zero records from Inputs tab');
  Logger.log('[v6_inputs] records=' + records.length + ' kills=' + killCount);

  const fin = _v6_finalise(records, 'v6_inputs_tab', V6_CONFIG.tables.inputs, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, sectionCounts, killCount };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 6 — CAPEX_TOOL TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushCapexTool() {
  _v6_showPushDialog(
    'Polaris V6 — Push CAPEX Tool',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> CAPEX_Tool<br>' +
    '<strong>Techs:</strong> Solar, Wind, BESS, Gas, DTC<br>' +
    '<strong>Rows:</strong> forecast, adder, total, variance, headers<br>' +
    '<strong>Columns:</strong> $/W unit cost + total $ + all 579 monthly columns',
    'v6_executeCapexPush', _v6_lastPush(V6_CONFIG.tables.capex), 540
  );
}

function v6_executeCapexPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processCapex(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('CAPEX_Tool: ' + result.rowCount + ' rows');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Types: ' + JSON.stringify(result.typeCounts));
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ CAPEX Tool pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processCapex(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const cfg   = V6_CONFIG.capex;
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.capex);
  if (!sheet) throw new Error('Tab not found: ' + V6_CONFIG.tabs.capex);

  const lastRow = sheet.getLastRow();
  const lastCol = sheet.getLastColumn();
  const allVals = sheet.getRange(1, 1, lastRow, lastCol).getValues();

  const monthHeaders = _v6_monthHeaders(allVals[0], cfg.monthlyStartCol);
  Logger.log('[v6_capex] monthly cols=' + monthHeaders.length);

  const records    = [];
  const typeCounts = {};

  for (let ri = 0; ri < allVals.length; ri++) {
    const row       = allVals[ri];
    const sourceRow = ri + 1;
    if (sourceRow <= 3) continue;
    if (!row.some(v => v !== null && v !== undefined && String(v).trim() !== '')) continue;

    const tech    = _v6_techFromRow(sourceRow, cfg.techSections);
    const colA    = String(row[0] || '').trim();
    const colBStr = String(row[1] !== null ? row[1] : '').trim();
    const colC    = row[2];   // $/W unit cost (raw number)
    const colD    = row[3];   // total $
    const colE    = row[4];   // unused in V6
    let rowType = 'header';
    if (colA === 'Capex & Devex Forecast') {
      rowType = 'forecast';
    } else if (colBStr === 'Total CAPEX') {
      rowType = 'total';
    } else if (colBStr === 'Variance') {
      rowType = 'variance';
    } else if (colBStr.includes('Calculator')) {
      rowType = 'section_header';
    } else if (colBStr === 'Capacity') {
      rowType = 'capacity';
    } else if (colBStr === 'Latest Actuals Date') {
      rowType = 'actuals_date';
    } else if (['$/Wp Adder','$/Wac Adder','$/Wh Adder','$/Wac Input','$/Wh Input',
                '$/Wp','$/Wac','$/Wh','$/Wh Input'].includes(String(row[2] || '').trim())) {
      rowType = 'adder_header';
    } else if (colBStr !== '' &&
               !['Total CAPEX','Variance','Capacity','Latest Actuals Date'].includes(colBStr) &&
               !colBStr.includes('Calculator') &&
               colD !== null && colD !== undefined && colD !== '') {
      rowType = 'forecast';
    }
    typeCounts[rowType] = (typeCounts[rowType] || 0) + 1;

    const rec = Object.assign(_v6_base(ss, V6_CONFIG.tabs.capex, V6_CONFIG.tables.capex,
                  runId, runType, label, notes, pushedAt, pushedBy), {
      source_row:      sourceRow,
      technology:      tech,
      row_type:        rowType,
      row_label:       colBStr || null,
      row_category:    colA || null,
      adder_value:     null,
      dollar_per_unit: _v6_fmtVal(colC),
      total_usd:       _v6_fmtVal(colD),
    });

    for (const mh of monthHeaders) {
      rec[mh.key] = _v6_fmtVal(row[mh.idx]);
    }
    records.push(rec);
  }
  if (!records.length) throw new Error('Zero records from CAPEX_Tool');
  Logger.log('[v6_capex] records=' + records.length + ' types=' + JSON.stringify(typeCounts));

  const fin = _v6_finalise(records, 'v6_capex_tool', V6_CONFIG.tables.capex, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, typeCounts };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 7 — OPEX_TOOL TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushOpexTool() {
  _v6_showPushDialog(
    'Polaris V6 — Push Opex Tool',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> Opex_Tool<br>' +
    '<strong>Sections:</strong> Flags, Solar, Wind, BESS, Gas, DTC<br>' +
    '<strong>Includes:</strong> All row types + all 579 monthly columns<br>' +
    '<strong>Row types:</strong> flag, schedule_input, calculated, line_item, total, franchise_tax, sub_header',
    'v6_executeOpexPush', _v6_lastPush(V6_CONFIG.tables.opex), 560
  );
}

function v6_executeOpexPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processOpex(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('Opex_Tool: ' + result.rowCount + ' rows');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Types: ' + JSON.stringify(result.typeCounts));
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ Opex Tool pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processOpex(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const cfg   = V6_CONFIG.opex;
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.opex);
  if (!sheet) throw new Error('Tab not found: ' + V6_CONFIG.tabs.opex);

  const lastRow = sheet.getLastRow();
  const lastCol = sheet.getLastColumn();
  const allVals = sheet.getRange(1, 1, lastRow, lastCol).getValues();

  const monthHeaders = _v6_monthHeaders(allVals[0], cfg.monthlyStartCol);
  Logger.log('[v6_opex] monthly cols=' + monthHeaders.length);

  const records    = [];
  const typeCounts = {};

  for (let ri = 0; ri < allVals.length; ri++) {
    const row       = allVals[ri];
    const sourceRow = ri + 1;
    if (sourceRow <= 3) continue;
    if (!row.some(v => v !== null && v !== undefined && String(v).trim() !== '')) continue;

    const tech    = _v6_techFromRow(sourceRow, cfg.techSections);
    const colB    = row[1];
    const colBStr = String(colB !== null && colB !== undefined ? colB : '').trim();
    const colC    = String(row[2] || '').trim();
    const colD    = row[3];
    const colE    = row[4];
    const colF    = row[5];

    if (colC === '' && colBStr === '' && colD === null && colE === null && colF === null) continue;

    let rowType = 'other';
    if (colC.startsWith('Operating Expenses -'))  rowType = 'section_header';
    else if (colC === 'Flags')                    rowType = 'flags_header';
    else if (colC.startsWith('NTP -') || colC.startsWith('Operation Period') ||
             colC.startsWith('Operating Year') || colC.startsWith('Installed Capacity') ||
             colC.startsWith('Number of Turbines') || colC === 'Production - Gas')
                                                   rowType = 'flag';
    else if (colBStr === '$/Yr' || colBStr === '$/MWp' || colBStr === '$/kWh' ||
             colBStr === '$/MWh' || colBStr.startsWith('$'))
                                                   rowType = 'flag';
    else if (colC === 'Variance')                  rowType = 'variance';
    else if (colC.startsWith('Total') && !colC.startsWith('Total Attributable'))
                                                   rowType = 'total';
    else if (colC === 'LCOE ($/MWh)' || colC === 'LCOE ($/kW-mo)' ||
             colC.startsWith('Franchise Tax') || colC.startsWith('Times:') ||
             colC.startsWith('Equals:') || colC === 'COGS' || colC.startsWith('1. 70%') ||
             ['Solar','Wind','BESS','Gas','DTC'].includes(colC))
                                                   rowType = 'franchise_tax';
    else if (colC.startsWith('Calculated O&M') || colC.startsWith('Calculated Insurance') ||
             colC.startsWith('Calculated Property') || colC === 'Other Expenses' ||
             colC === 'Other Costs' || colC === 'Operating LCs' ||
             colC === 'Forecasted Opex Schedules' || colC === 'Input Schedules' || colC === 'Schedules')
                                                   rowType = 'sub_header';
    else if (colBStr !== '' && !isNaN(parseFloat(colBStr)) && colC !== '')
                                                   rowType = 'line_item';
    else if (['Covered O&M','Non-Covered O&M','Asset Management','Major Maintenance',
              'O&M & Asset Management','Property Premium','Business Interruption Premium',
              'Insurance','Spend to Date','Percent Good','Tax Basis for Accrual',
              'Effective Millage Rate','Property Tax Accrual','Tax Abatement Payment Accrual',
              'Ag Rollback Payment Accrual','Property Taxes','Fuel Cost','Firm Transmission',
              'Fuel OpEx','MMBTUs','Generator Fixed O&M','Generator Variable O&M',
              'Operating Personnel','Parasitic Load'].includes(colC) ||
             colC.startsWith('Total Attributable') || colC.startsWith('Gas Schedule'))
                                                   rowType = 'calculated';
    else if (colC !== '' && (colE !== null && colE !== undefined && colE !== '' ||
             colF !== null && colF !== undefined && colF !== ''))
                                                   rowType = 'schedule_input';

    typeCounts[rowType] = (typeCounts[rowType] || 0) + 1;

    const rec = Object.assign(_v6_base(ss, V6_CONFIG.tabs.opex, V6_CONFIG.tables.opex,
                  runId, runType, label, notes, pushedAt, pushedBy), {
      source_row:    sourceRow,
      technology:    tech,
      row_type:      rowType,
      row_label:     colC || null,
      unit_label:    (colBStr && isNaN(parseFloat(colBStr)) && colBStr !== '') ? colBStr : null,
      line_item_num: (!isNaN(parseFloat(colBStr)) && colBStr !== '') ? parseFloat(colBStr) : null,
      flag_value:    colD instanceof Date ? _v6_fmtDate(colD) : _v6_fmtVal(colD),
      pre_cod_value: _v6_fmtVal(colE),
      total_value:   _v6_fmtVal(colF),
    });

    for (const mh of monthHeaders) {
      rec[mh.key] = _v6_fmtVal(row[mh.idx]);
    }
    records.push(rec);
  }
  if (!records.length) throw new Error('Zero records from Opex_Tool');
  Logger.log('[v6_opex] records=' + records.length + ' types=' + JSON.stringify(typeCounts));

  const fin = _v6_finalise(records, 'v6_opex_tool', V6_CONFIG.tables.opex, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, typeCounts };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 8 — 20yrLCOECalc TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushLcoeCalcs() {
  _v6_showPushDialog(
    'Polaris V6 — Snapshot 20yr LCOE Calcs',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> 20yrLCOECalc &nbsp;(calculated output — audit snapshot)<br>' +
    '<strong>Techs:</strong> Facility, Solar, Wind, Gas, BESS<br>' +
    '<strong>Metrics:</strong> LCOE, Generation/Capacity, Capex, Opex, Credit Monetization, Depreciation, Fuel Opex<br>' +
    '<strong>Format:</strong> Long — 1 row per tech × metric × year',
    'v6_executeLcoeCalcsPush', _v6_lastPush(V6_CONFIG.tables.lcoeCalcs), 580
  );
}

function v6_executeLcoeCalcsPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processLcoeCalcs(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('20yrLCOECalc: ' + result.rowCount + ' records');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Tech counts: ' + JSON.stringify(result.techCounts));
    lines.push('LCOE validation:');
    Object.entries(result.lcoeValues).forEach(([tech, val]) => {
      if (val === null) { lines.push('  ' + tech + ': null'); return; }
      const exp  = V6_CONFIG.lcoeCalcs.expectedLcoe[tech];
      const diff = Math.abs(val - exp);
      lines.push('  ' + tech + ': ' + val.toFixed(3) + ' (exp ' + exp + ') ' + (diff < 0.01 ? '✓' : '⚠ MISMATCH'));
    });
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ LCOE Calcs snapshotted', runId, lines, pushedAt, pushedBy);
}

function _v6_processLcoeCalcs(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const cfg   = V6_CONFIG.lcoeCalcs;
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.lcoeCalcs);
  if (!sheet) throw new Error('Tab not found: ' + V6_CONFIG.tabs.lcoeCalcs);

  const maxRow  = 52;
  const maxCol  = 52;
  const allVals = sheet.getRange(1, 1, maxRow, maxCol).getValues();

  const yearRow  = allVals[4];
  const yearCols = [];
  for (let c = cfg.yearStartCol - 1; c < maxCol; c++) {
    const v = yearRow[c];
    if (v && !isNaN(parseInt(v))) yearCols.push({ colIdx: c, year: parseInt(v) });
  }
  Logger.log('[v6_lcoeCalcs] year cols=' + yearCols.length +
             ' (' + yearCols[0].year + '-' + yearCols[yearCols.length - 1].year + ')');

  const records    = [];
  const techCounts = {};
  const lcoeValues = {};

  for (const block of cfg.techBlocks) {
    const tech        = block.technology;
    techCounts[tech]  = 0;
    const lcoeRowData = allVals[block.lcoeRow - 1];
    const lcoeNum     = lcoeRowData[2] !== null && !isNaN(parseFloat(lcoeRowData[2])) ?
                        parseFloat(lcoeRowData[2]) : null;
    lcoeValues[tech]  = lcoeNum;

    for (const mr of block.metricRows) {
      const rowData       = allVals[mr.row - 1];
      const lifetimeTotal = rowData[3] !== null && !isNaN(parseFloat(rowData[3])) ?
                            parseFloat(rowData[3]) : null;

      for (const yc of yearCols) {
        const raw       = rowData[yc.colIdx];
        const annualVal = (raw !== null && raw !== undefined && String(raw).trim() !== '' &&
                           !isNaN(parseFloat(raw))) ? parseFloat(raw) : null;

        records.push(Object.assign(_v6_base(ss, V6_CONFIG.tabs.lcoeCalcs, V6_CONFIG.tables.lcoeCalcs,
                       runId, runType, label, notes, pushedAt, pushedBy), {
          source_row:     mr.row,
          technology:     tech,
          metric:         mr.metric,
          lcoe_value:     lcoeNum,
          lifetime_total: lifetimeTotal,
          year:           yc.year,
          annual_value:   annualVal,
        }));
        techCounts[tech]++;
      }
    }
  }
  if (!records.length) throw new Error('Zero records from 20yrLCOECalc');
  Logger.log('[v6_lcoeCalcs] records=' + records.length + ' techs=' + JSON.stringify(techCounts));
  Logger.log('[v6_lcoeCalcs] LCOEs=' + JSON.stringify(lcoeValues));

  const fin = _v6_finalise(records, 'v6_lcoe_calcs', V6_CONFIG.tables.lcoeCalcs, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, techCounts, lcoeValues };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 9 — PRO FORMA SUMMARY (4 tabs) — available individually, excluded from Push All
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushProFormaSummary() {
  _v6_showPushDialog(
    'Polaris V6 — Push Pro Forma Summary',
    V6_CONFIG.modelName,
    '<strong>Tabs:</strong> Solar_Pro_Forma, Wind_Pro_Forma, BESS_Pro_Forma, Gas_Pro_Forma<br>' +
    '<strong>Rows:</strong> 3–13 (LCOE Inputs summary block, cols D–E)<br>' +
    '<strong>Metrics:</strong> Generation, Project Costs, OpEx, ITC Monetization, Tax Deferral, Tax Savings + CTG versions<br>' +
    '<strong>Format:</strong> Long — 1 row per metric per technology (44 records)',
    'v6_executeProFormaPush', _v6_lastPush(V6_CONFIG.tables.proForma), 560
  );
}

function v6_executeProFormaPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processProForma(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('Pro Forma Summary: ' + result.rowCount + ' records');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Per tech: ' + JSON.stringify(result.techCounts));
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ Pro Forma Summary pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processProForma(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const cfg     = V6_CONFIG.proForma;
  const records = [];
  const techCounts = {};

  for (const tabCfg of cfg.tabs) {
    const tabName = V6_CONFIG.tabs[tabCfg.tabKey];
    const sheet   = ss.getSheetByName(tabName);
    if (!sheet) { Logger.log('WARN: tab not found: ' + tabName); continue; }

    const tech       = tabCfg.technology;
    techCounts[tech] = 0;
    const numRows    = cfg.summaryEndRow - cfg.summaryStartRow + 1;
    const data       = sheet.getRange(cfg.summaryStartRow, cfg.labelCol, numRows, 2).getValues();

    for (let i = 0; i < data.length; i++) {
      const srcRow      = cfg.summaryStartRow + i;
      const metricLabel = String(data[i][0] || '').trim();
      if (!metricLabel) continue;

      const rawVal  = data[i][1];
      const valNum  = (rawVal !== null && rawVal !== undefined && String(rawVal).trim() !== '' &&
                       !isNaN(parseFloat(String(rawVal)))) ? parseFloat(String(rawVal)) : null;
      const isCtg   = metricLabel.toUpperCase().startsWith('CTG');
      const metricKey = (isCtg ? 'ctg_' : '') +
                        metricLabel.replace(/^CTG\s+/i, '').replace(/\s*\(.*?\)\s*/g, '')
                          .trim().toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '');

      records.push(Object.assign(_v6_base(ss, tabName, V6_CONFIG.tables.proForma,
                     runId, runType, label, notes, pushedAt, pushedBy), {
        source_row: srcRow, technology: tech, metric_label: metricLabel,
        metric_key: metricKey, is_ctg: isCtg, value: valNum,
      }));
      techCounts[tech]++;
    }
  }
  if (!records.length) throw new Error('Zero records from pro forma tabs');
  Logger.log('[v6_proForma] records=' + records.length + ' techs=' + JSON.stringify(techCounts));

  const fin = _v6_finalise(records, 'v6_pro_forma_summary', V6_CONFIG.tables.proForma, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, techCounts };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 10 — OUTPUT_SUMMARY TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushOutputSummary() {
  _v6_showPushDialog(
    'Polaris V6 — Push Output Summary',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> Output_Summary<br>' +
    '<strong>Captures:</strong> RLR table (Return/Speed/Liquidity/Risk), CapEx detail by tech, Tech Liquidity (annual + monthly)<br>' +
    '<strong>Format:</strong> Flat — 1 record per metric with Budget / Current Forecast / Proposed Forecast columns',
    'v6_executeOutputSummaryPush', _v6_lastPush(V6_CONFIG.tables.outputSummary), 540
  );
}

function v6_executeOutputSummaryPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processOutputSummary(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('Output Summary: ' + result.rowCount + ' records');
    lines.push('Snapshot: ' + result.snapshotId);
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ Output Summary pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processOutputSummary(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.outputSummary);
  if (!sheet) throw new Error('Tab not found: ' + V6_CONFIG.tabs.outputSummary);

  const allVals = sheet.getRange(1, 1, 55, 15).getValues();
  const records = [];

  const baseRec = () => _v6_base(ss, V6_CONFIG.tabs.outputSummary, V6_CONFIG.tables.outputSummary,
                    runId, runType, label, notes, pushedAt, pushedBy);

  const RLR = [
    [1,  'Return',    'Facility LCOE ($/MWh)'],
    [2,  'Return',    'PV LCOE ($/MWh)'],
    [3,  'Return',    'Wind LCOE ($/MWh)'],
    [4,  'Return',    'BESS LCOE ($/MWh)'],
    [5,  'Return',    'Gas LCOE ($/MWh)'],
    [6,  'Return',    'CFE (%)'],
    [7,  'Speed',     'Speed to Power'],
    [8,  'Liquidity', 'Total Project Capex excl. contingency'],
    [9,  'Liquidity', 'Contingency'],
    [10, 'Liquidity', 'Current Quarter Capex'],
    [11, 'Liquidity', 'Remainder of Year Capex'],
    [12, 'Risk',      'Reliability'],
    [13, 'Risk',      'Other Risks and Opportunities'],
  ];
  for (const [ri, category, metric] of RLR) {
    const row = allVals[ri];
    records.push(Object.assign(baseRec(), {
      section: 'RLR_Table', source_row: ri + 1, category, metric,
      budget: _v6_fmtVal(row[3]), current_forecast: _v6_fmtVal(row[4]), proposed_forecast: _v6_fmtVal(row[5]),
    }));
  }

  const capexHdr  = allVals[25];
  const capexCols = capexHdr.slice(2).map((v, i) => v ? String(v).trim() : 'col_' + (i + 3));
  for (let ri = 26; ri <= 33; ri++) {
    const row = allVals[ri];
    const tech = _v6_fmtVal(row[1]);
    if (!tech) continue;
    const rec = Object.assign(baseRec(), { section: 'Capex_Detail', source_row: ri + 1, tech });
    capexCols.forEach((col, ci) => { rec[col] = _v6_fmtVal(row[ci + 2]); });
    records.push(rec);
  }

  const annHdr  = allVals[35];
  const annCols = annHdr.slice(1).map((v, i) =>
    v instanceof Date ? _v6_fmtDate(v) : (v ? String(v).trim() : 'col_' + (i + 2)));
  for (let ri = 36; ri <= 44; ri++) {
    const row = allVals[ri];
    const tech = _v6_fmtVal(row[1]);
    if (!tech) continue;
    const rec = Object.assign(baseRec(), { section: 'Tech_Liquidity_Annual', source_row: ri + 1, tech });
    annCols.forEach((col, ci) => { if (col) rec[col] = _v6_fmtVal(row[ci + 1]); });
    records.push(rec);
  }

  const moHdr  = allVals[45];
  const moCols = moHdr.slice(1).map((v, i) =>
    v instanceof Date ? _v6_fmtDate(v) : (v ? String(v).trim() : 'col_' + (i + 2)));
  for (let ri = 46; ri <= 54; ri++) {
    if (ri >= allVals.length) break;
    const row = allVals[ri];
    const tech = _v6_fmtVal(row[1]);
    if (!tech) continue;
    const rec = Object.assign(baseRec(), { section: 'Tech_Liquidity_Monthly', source_row: ri + 1, tech });
    moCols.forEach((col, ci) => { if (col) rec[col] = _v6_fmtVal(row[ci + 1]); });
    records.push(rec);
  }

  if (!records.length) throw new Error('Zero records from Output_Summary');
  Logger.log('[v6_outputSummary] records=' + records.length);

  const fin = _v6_finalise(records, 'v6_output_summary', V6_CONFIG.tables.outputSummary, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 11 — SIGN OFF SHEET TAB
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushSignOffSheet() {
  _v6_showPushDialog(
    'Polaris V6 — Push Sign Off Sheet',
    V6_CONFIG.modelName,
    '<strong>Tab:</strong> Sign Off Sheet (~570 non-empty rows)<br>' +
    '<strong>Captures:</strong> Every input\'s owner, source file, department, sign-off status, date<br>' +
    '<strong>Fields:</strong> input_id, input_name, project, case, date_of_input, source_file, department, owner, sign_off, section_group',
    'v6_executeSignOffPush', _v6_lastPush(V6_CONFIG.tables.signOff), 540
  );
}

function v6_executeSignOffPush(label, runType, notes) {
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  let result, errMsg;
  try   { result = _v6_processSignOff(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate); }
  catch (e) { errMsg = e.message; }

  const lines = [];
  if (result) {
    lines.push('Sign Off Sheet: ' + result.rowCount + ' records');
    lines.push('Snapshot: ' + result.snapshotId);
    lines.push('Groups: ' + JSON.stringify(result.groupCounts));
    if (result.bqJobId) lines.push('BQ job: ' + result.bqJobId);
    if (result.bqError) lines.push('⚠ BQ: ' + result.bqError.substring(0, 80));
  }
  if (errMsg) lines.push('ERROR: ' + errMsg);
  _v6_alert(V6_CONFIG.devMode ? 'DEV preview' : '✅ Sign Off Sheet pushed', runId, lines, pushedAt, pushedBy);
}

function _v6_processSignOff(ss, runId, label, runType, notes, pushedAt, pushedBy, snapDate) {
  const sheet = ss.getSheetByName(V6_CONFIG.tabs.signOff);
  if (!sheet) throw new Error('Tab not found: "' + V6_CONFIG.tabs.signOff + '" — check for leading space');

  const lastRow = sheet.getLastRow();
  const allVals = sheet.getRange(1, 1, lastRow, 10).getValues();
  const records     = [];
  const groupCounts = {};
  let currentGroup  = 'General';

  const GROUP_NAMES = new Set([
    'Static Inputs','MW Plan','Construction Start Date','Substantial Completion',
    'End of Useful Life','Capacities','Y1 Generation','Degradation',
    'ITC Eligibility','Tax Attributes','Depreciation','Underwriting & Financing Fees',
    'Contingency','CAPEX Inputs','OPEX Rate Inputs','Land Lease Inputs',
    'Insurance Inputs','Property Tax Inputs','Operating LCs','Other Expenses',
    'Gas OPEX','DTC OPEX','Live Gas Curves','Live PTC Inflation Curve',
  ]);

  for (let ri = 0; ri < allVals.length; ri++) {
    const row       = allVals[ri];
    const sourceRow = ri + 1;
    const inputId   = _v6_fmtVal(row[1]);
    const inputName = row[2] !== null && row[2] !== undefined ? String(row[2]).trim() : null;
    if (!inputName) continue;

    const project = _v6_fmtVal(row[3]);
    if (project === null && GROUP_NAMES.has(inputName)) { currentGroup = inputName; continue; }
    if (project === null && inputId === null) continue;

    groupCounts[currentGroup] = (groupCounts[currentGroup] || 0) + 1;

    records.push(Object.assign(_v6_base(ss, V6_CONFIG.tabs.signOff, V6_CONFIG.tables.signOff,
                   runId, runType, label, notes, pushedAt, pushedBy), {
      source_row:    sourceRow,
      section_group: currentGroup,
      input_id:      inputId,
      input_name:    inputName,
      project:       project,
      case:          _v6_fmtVal(row[4]),
      date_of_input: _v6_fmtVal(row[5]),
      source_file:   _v6_fmtVal(row[6]),
      department:    _v6_fmtVal(row[7]),
      owner:         _v6_fmtVal(row[8]),
      sign_off:      _v6_fmtVal(row[9]),
    }));
  }
  if (!records.length) throw new Error('Zero records from Sign Off Sheet');
  Logger.log('[v6_signOff] records=' + records.length + ' groups=' + JSON.stringify(groupCounts));

  const fin = _v6_finalise(records, 'v6_sign_off_sheet', V6_CONFIG.tables.signOff, runId, snapDate);
  return { rowCount: records.length, snapshotId: fin.snapshotId, bqJobId: fin.bqJobId, bqError: fin.bqError, groupCounts };
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 12 — SETUP CHECKER
// ═══════════════════════════════════════════════════════════════════════════════

function v6_checkSetup() {
  const ui  = SpreadsheetApp.getUi();
  const ss  = SpreadsheetApp.getActive();
  const ok  = [];
  const issues = [];

  for (const [key, name] of Object.entries(V6_CONFIG.tabs)) {
    const sheet = ss.getSheetByName(name);
    if (!sheet) issues.push('Tab not found: "' + name + '" (key: ' + key + ')');
    else ok.push('Tab OK: "' + name + '" (' + sheet.getLastRow() + ' rows, ' + sheet.getLastColumn() + ' cols)');
  }

  ok.push('GCS: gs://' + V6_CONFIG.gcsBucket + '/' + V6_CONFIG.gcsPrefix + '/');
  ok.push('BQ:  ' + V6_CONFIG.bqProjectId + '.' + V6_CONFIG.bqDatasetId);
  ok.push('Mode: ' + (V6_CONFIG.devMode ? 'DEV (no writes)' : 'LIVE'));

  try { ScriptApp.getOAuthToken(); ok.push('OAuth token available'); }
  catch (e) { issues.push('OAuth error: ' + e.message); }

  let msg = 'OK:\n  ' + ok.join('\n  ');
  if (issues.length) msg += '\n\nISSUES:\n  ' + issues.join('\n  ');
  else msg += '\n\nAll checks passed. Ready to push.';

  ui.alert('Polaris V6 setup check', msg, ui.ButtonSet.OK);
}


// Headless variant for invocation via the Apps Script Execution API (`clasp run`).
// Accepts the target spreadsheet ID as a parameter, returns the result as a string
// instead of calling ui.alert(). v6_checkSetup() stays intact for the sheet menu.
function v6_checkSetup_cli(sheetId) {
  if (!sheetId) {
    return 'ERROR: sheetId is required. Call as: clasp run v6_checkSetup_cli --params \'["<spreadsheet-id>"]\'';
  }
  let ss;
  try { ss = SpreadsheetApp.openById(sheetId); }
  catch (e) { return 'ERROR: cannot open spreadsheet "' + sheetId + '": ' + e.message; }

  const ok = [];
  const issues = [];

  ok.push('Spreadsheet: "' + ss.getName() + '" (id: ' + sheetId + ')');

  for (const [key, name] of Object.entries(V6_CONFIG.tabs)) {
    const sheet = ss.getSheetByName(name);
    if (!sheet) issues.push('Tab not found: "' + name + '" (key: ' + key + ')');
    else ok.push('Tab OK: "' + name + '" (' + sheet.getLastRow() + ' rows, ' + sheet.getLastColumn() + ' cols)');
  }

  ok.push('GCS: gs://' + V6_CONFIG.gcsBucket + '/' + V6_CONFIG.gcsPrefix + '/');
  ok.push('BQ:  ' + V6_CONFIG.bqProjectId + '.' + V6_CONFIG.bqDatasetId);
  ok.push('Mode: ' + (V6_CONFIG.devMode ? 'DEV (no writes)' : 'LIVE'));

  try { ScriptApp.getOAuthToken(); ok.push('OAuth token available'); }
  catch (e) { issues.push('OAuth error: ' + e.message); }

  let msg = 'OK:\n  ' + ok.join('\n  ');
  if (issues.length) msg += '\n\nISSUES:\n  ' + issues.join('\n  ');
  else msg += '\n\nAll checks passed. Ready to push.';
  return msg;
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 13 — DEV RUNNERS
// ═══════════════════════════════════════════════════════════════════════════════

function _v6_devInputs()       { V6_CONFIG.devMode = true; v6_executeInputsPush('dev-test', 'test', ''); }
function _v6_devCapex()        { V6_CONFIG.devMode = true; v6_executeCapexPush('dev-test', 'test', ''); }
function _v6_devOpex()         { V6_CONFIG.devMode = true; v6_executeOpexPush('dev-test', 'test', ''); }
function _v6_devLcoeCalcs()    { V6_CONFIG.devMode = true; v6_executeLcoeCalcsPush('dev-test', 'test', ''); }
function _v6_devProForma()     { V6_CONFIG.devMode = true; v6_executeProFormaPush('dev-test', 'test', ''); }
function _v6_devOutputSummary(){ V6_CONFIG.devMode = true; v6_executeOutputSummaryPush('dev-test', 'test', ''); }
function _v6_devSignOff()      { V6_CONFIG.devMode = true; v6_executeSignOffPush('dev-test', 'test', ''); }

function _v6_devAll() {
  V6_CONFIG.devMode = true;
  Logger.log('=== V6 DEV RUN ALL TABS ===');
  _v6_devInputs();
  _v6_devCapex();
  _v6_devOpex();
  Logger.log('=== DONE ===');
}


// ═══════════════════════════════════════════════════════════════════════════════
// SECTION 14 — PUSH ALL TABS (Pro Forma excluded)
// ═══════════════════════════════════════════════════════════════════════════════

function v6_pushAll() {
  _v6_showPushDialog(
    'Polaris V6 — Push ALL Tabs',
    V6_CONFIG.modelName,
    '<strong>Pushes 3 tabs in sequence with the same run_id:</strong><br>' +
    'Inputs, CAPEX_Tool, Opex_Tool<br>' +
    '<em>Other tabs available individually via menu.</em><br><br>' +
    '<strong>Estimated time:</strong> ~8 minutes<br>' +
    '<strong>All outputs share one run_id</strong> — queryable together in BQ',
    'v6_executeAllPush', null, 520
  );
}

function v6_executeAllPush(label, runType, notes) {
  const ui         = SpreadsheetApp.getUi();
  const ss         = SpreadsheetApp.getActive();
  const cleanLabel = label.replace(/[^a-zA-Z0-9_\-]/g, '_') || 'unlabeled';
  const runId      = _v6_runId(cleanLabel);
  const pushedAt   = new Date().toISOString();
  const pushedBy   = Session.getActiveUser().getEmail() || 'unknown';
  const snapDate   = _v6_fmtDate(new Date());

  const TABS = [
    { name: 'Inputs',       fn: _v6_processInputs,    slug: 'inputs_tab' },
    { name: 'CAPEX_Tool',   fn: _v6_processCapex,     slug: 'capex_tool' },
    { name: 'Opex_Tool',    fn: _v6_processOpex,      slug: 'opex_tool'  },
    { name: '20yrLCOECalc', fn: _v6_processLcoeCalcs, slug: 'lcoe_calcs' },
  ];

  const lines = ['Run ID: ' + runId, ''];
  let anyError = false;

  for (const tab of TABS) {
    try {
      const result = tab.fn(ss, runId, cleanLabel, runType, notes, pushedAt, pushedBy, snapDate);
      let line = tab.name + ': ' + result.rowCount + ' records';
      if (result.bqJobId) line += '  BQ ✓';
      if (result.bqError) line += '  ⚠ BQ: ' + result.bqError.substring(0, 60);
      if (result.lcoeValues) {
        const v = result.lcoeValues;
        line += '\n  LCOEs → Facility:' + (v.Facility||'?').toFixed(2) +
                ' Solar:'   + (v.Solar||'?').toFixed(2) +
                ' Wind:'    + (v.Wind||'?').toFixed(2) +
                ' Gas:'     + (v.Gas||'?').toFixed(2) +
                ' BESS:'    + (v.BESS||'?').toFixed(2);
      }
      lines.push('✅ ' + line);
    } catch(e) {
      lines.push('❌ ' + tab.name + ': ' + e.message);
      anyError = true;
      Logger.log('[v6_pushAll] ERROR on ' + tab.name + ': ' + e.message);
    }
  }

  const t = Utilities.formatDate(new Date(pushedAt), Session.getScriptTimeZone(), "MMM d, yyyy 'at' h:mm a z");
  lines.push('');
  lines.push('Pushed at: ' + t);
  lines.push('Pushed by: ' + pushedBy);
  if (V6_CONFIG.devMode) lines.push('\nDEV mode — set devMode:false to write to GCS + BQ.');

  ui.alert(
    anyError ? '⚠ Push All — some errors' : (V6_CONFIG.devMode ? 'DEV preview complete' : '✅ All tabs pushed'),
    lines.join('\n'),
    ui.ButtonSet.OK
  );
}