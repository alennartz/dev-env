const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

// Run setup-env.js with a test workspace name
const scriptPath = path.join(__dirname, '..', 'template', 'setup-env.js');
const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), 'setup-env-test-'));
const envFile = path.join(tmpDir, '.env');

// Copy the script to tmp so it writes .env there
const testScript = path.join(tmpDir, 'setup-env.js');
try {
    fs.copyFileSync(scriptPath, testScript);
} catch (e) {
    console.log('FAIL: setup-env.js does not exist yet');
    process.exit(1);
}

execSync(`node "${testScript}" my-project`, { cwd: tmpDir });

const content = fs.readFileSync(envFile, 'utf8');

// Check LOCAL_WORKSPACE_FOLDER_BASENAME
if (!content.includes('LOCAL_WORKSPACE_FOLDER_BASENAME=my-project')) {
    console.log('FAIL: missing LOCAL_WORKSPACE_FOLDER_BASENAME');
    console.log('Got:', content);
    process.exit(1);
}

// Check HOME is set to os.homedir()
const home = os.homedir();
if (!content.includes(`HOME=${home}`)) {
    console.log(`FAIL: expected HOME=${home}`);
    console.log('Got:', content);
    process.exit(1);
}

// Cleanup
fs.rmSync(tmpDir, { recursive: true });
console.log('PASS: setup-env.js produces correct .env');
