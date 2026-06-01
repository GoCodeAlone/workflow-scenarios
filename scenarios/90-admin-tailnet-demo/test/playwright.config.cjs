const path = require('path');

module.exports = {
  testDir: path.join(__dirname, 'playwright'),
  outputDir: path.join(__dirname, 'playwright-output'),
  reporter: [['line']],
  use: {
    baseURL: process.env.BASE || 'http://127.0.0.1:18080',
    viewport: { width: 1440, height: 960 },
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
};
