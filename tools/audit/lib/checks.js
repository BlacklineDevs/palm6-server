// Loading the checks lives here rather than in run.js so that selftest.js can
// load them without requiring run.js, which requires selftest.js. A circular
// require is easy to write and confusing to debug; one small module avoids it.
'use strict';

const fs = require('fs');
const path = require('path');

const CHECK_DIR = path.join(__dirname, '..', 'checks');

function loadChecks() {
    return fs.readdirSync(CHECK_DIR)
        .filter((f) => f.endsWith('.js'))
        .sort()
        .map((f) => require(path.join(CHECK_DIR, f)));
}

module.exports = { loadChecks, CHECK_DIR };
