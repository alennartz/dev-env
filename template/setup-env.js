// Cross-platform .env generator for VS Code Dev Containers
// Called by devcontainer.json initializeCommand
// Usage: node setup-env.js <workspace-folder-basename>
const fs = require('fs');
const path = require('path');
const os = require('os');

const workspaceName = process.argv[2] || 'project';
const envFile = path.join(__dirname, '.env');

const lines = [
    `LOCAL_WORKSPACE_FOLDER_BASENAME=${workspaceName}`,
    `HOME=${os.homedir()}`,
];

fs.writeFileSync(envFile, lines.join('\n') + '\n');
