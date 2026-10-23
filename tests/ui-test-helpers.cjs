const path = require('path');
const { pathToFileURL } = require('url');
const { chromium } = require('playwright');
const root = path.resolve(__dirname, '..');
module.exports = { chromium, root, fileURL: name => pathToFileURL(path.join(root, 'src/ui', name + '.html')).href };
