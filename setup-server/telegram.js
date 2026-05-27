'use strict';

// Pure interpretation of a Telegram getMe response. Kept separate from
// server.js (which has import-time side effects) so it can be unit-tested.
//
// Telegram's getMe returns { ok: true, result: {...} } on success, or
// { ok: false, error_code, description } on failure. Only error_code 401
// means the token is genuinely wrong/revoked — every other failure (429
// Too Many Requests, 5xx) is transient and must NOT cause us to reject a
// token the user typed correctly.
function interpretGetMe(httpStatus, body) {
  if (body && body.ok && body.result && body.result.username) {
    return {
      ok: true,
      username: body.result.username,
      firstName: body.result.first_name,
    };
  }
  const code = body && body.error_code;
  if (code === 401) {
    return {
      ok: false,
      reason: 'unauthorized',
      detail: (body && body.description) || 'Telegram rejected this bot token',
    };
  }
  // 429 / 5xx / unparseable — treat as transient so we don't falsely reject
  // a valid token when Telegram is rate-limiting or briefly down.
  return {
    ok: false,
    reason: 'transient',
    networkFailure: true,
    detail: (body && body.description) || ('Telegram returned ' + (code || httpStatus || 'no response')),
  };
}

module.exports = { interpretGetMe };
