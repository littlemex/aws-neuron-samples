import { expect, Page, Locator } from '@playwright/test';

/**
 * Cognito Hosted UI on *.amazoncognito.com.
 *
 * The Hosted UI markup is stable enough across Cognito releases that
 * targeting `input[name=username]` / `input[name=password]` works
 * without scraping data-testids (which Cognito does not provide).
 * If AWS ever changes the markup, this single class is the seam.
 */
export class CognitoLoginPage {
  readonly username: Locator;
  readonly password: Locator;
  readonly submit: Locator;
  readonly forceChangeBanner: Locator;

  constructor(public readonly page: Page) {
    this.username = page.locator('input[name=username]');
    this.password = page.locator('input[name=password]');
    this.submit = page.locator('input[type=submit], button[type=submit]').first();
    // Cognito shows a "Change password" form on the first login when
    // admin-create-user used a temporary password. We detect it so the
    // test can either fail-fast or self-heal via admin-set-user-password.
    this.forceChangeBanner = page.locator('text=/change.*password/i');
  }

  async expectVisible() {
    await expect(this.username).toBeVisible({ timeout: 30_000 });
    await expect(this.password).toBeVisible();
    await expect(this.submit).toBeVisible();
  }

  async login(email: string, password: string) {
    await this.username.fill(email);
    await this.password.fill(password);
    await this.submit.click();
  }
}
