import { expect, Page, Locator } from '@playwright/test';

/**
 * code-server post-auth landing page.
 *
 * After OAuth succeeds, CloudFront forwards the request to the ALB and
 * code-server renders its own login page (separate from Cognito) gated
 * by CODE_SERVER_PASSWORD. We don't fill that form in the journey
 * because the operator's threat model treats code-server's password as
 * defense-in-depth, not the primary auth boundary.
 *
 * What we *do* assert is that the cf_session cookie has been set and
 * that we reached code-server's HTML (workbench shell or its login
 * form), proving the OAuth proxy round-trip closed cleanly.
 */
export class CodeServerPage {
  // code-server's own password prompt. This is the expected first
  // visible UI after OAuth on a fresh browser. We just check it's
  // there - filling it requires the operator's CODE_SERVER_PASSWORD
  // which we deliberately keep out of the e2e env to stay scoped to
  // the OAuth boundary.
  readonly codeServerPasswordField: Locator;
  // The workbench shell - present only if the browser already had a
  // code-server session. Either-or with the password prompt.
  readonly workbench: Locator;

  constructor(public readonly page: Page) {
    this.codeServerPasswordField = page.locator('input[type=password][name=password]');
    this.workbench = page.locator('.monaco-workbench');
  }

  /**
   * Confirms we landed on code-server (one of: password prompt OR
   * workbench shell). The OAuth boundary is what we're testing; we
   * don't proceed past code-server's own gate.
   */
  async expectReached() {
    const passwordVisible = this.codeServerPasswordField.isVisible().catch(() => false);
    const workbenchVisible = this.workbench.isVisible().catch(() => false);
    const [pw, wb] = await Promise.all([passwordVisible, workbenchVisible]);
    expect(pw || wb, 'expected either code-server password prompt or workbench').toBe(true);
  }
}
