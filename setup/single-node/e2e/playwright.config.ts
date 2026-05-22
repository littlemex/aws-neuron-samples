import { defineConfig, devices } from '@playwright/test';

// Required env (set after `bash deploy.sh ... --create-cloudfront-frontend`):
//   CF_BASE_URL          https://dXXXX.cloudfront.net   (CloudFront output)
//   TEST_USER_EMAIL      operator account email          (admin-create-user)
//   TEST_USER_PASSWORD   permanent password set via admin-set-user-password
//
// Until those are present, `npx playwright test` aborts in the global
// setup with a clear message rather than silently failing in the
// browser. Keep it that way - implicit fallbacks (e.g. localhost) hide
// real misconfiguration.

const baseURL = process.env.CF_BASE_URL;

export default defineConfig({
  testDir: './tests',
  outputDir: './artifacts/test-results',
  reporter: [
    ['list'],
    ['html', { outputFolder: './artifacts/playwright-report', open: 'never' }],
    ['junit', { outputFile: './artifacts/junit.xml' }],
  ],
  retries: 1,
  use: {
    baseURL,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
    // CloudFront caches absolutely nothing on /oauth/* (cdk stack sets
    // CACHING_DISABLED), but it does cache the default behavior. We
    // pass a deterministic UA so any 403 from WAF (when added later)
    // is identifiable in CloudFront logs.
    userAgent: 'single-node-e2e/playwright',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
  globalSetup: './tests/global-setup.ts',
});
