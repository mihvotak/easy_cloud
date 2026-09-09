# Authentication flow

## Scope

The first application version uses an email address and a Mail.ru application
password. A normal account password must not be accepted or described as
supported. VK ID browser authentication is deferred.

## Login

```text
POST https://o2.mail.ru/token
Content-Type: application/x-www-form-urlencoded

client_id=cloud-win
grant_type=password
username=<full email>
password=<application password>
```

Expected fields:

```text
access_token, refresh_token, expires_in,
error, error_code, error_description
```

The default client ID comes from the current `CloudMailRu`. The older mobile
implementation uses `cloud-android`, supports a second-factor response, and
implements refresh. Both variants require live verification.

## CSRF

After login:

```text
GET https://cloud.mail.ru/api/v2/tokens/csrf
    ?access_token=<access token>
```

Read `body.token` and send it as `X-CSRF-Token` on API requests. The OAuth
access token remains the API query credential. Tokens in query strings make
URL redaction mandatory.

## Refresh

Candidate flow from `WebDavMailRuCloud`:

```text
POST https://o2.mail.ru/token

client_id=<same client ID>
grant_type=refresh_token
refresh_token=<refresh token>
```

This flow is not implemented by the current `CloudMailRu`, despite that client
parsing a refresh token. A production probe with `cloud-win` confirmed it on
2026-09-09. The response rotated both access and refresh tokens and reported a
3600-second lifetime.

Refresh in the application must be guarded by one asynchronous mutex. After a
successful refresh it obtains a new CSRF token and retries the original request
once. After a failed refresh it reports `AuthRequired`; it must not loop.

## Secret handling

The probe:

- reads `CLOUD_MAIL_EMAIL` and `CLOUD_MAIL_APP_PASSWORD`, or prompts locally;
- disables terminal echo while reading the password when possible;
- never writes a token or password to disk;
- never accepts a password command-line argument;
- redacts credentials in URLs, form bodies, headers, JSON, and exceptions.

For repeated read-only contract checks, `cloud_probe suite` keeps credentials
only in process memory and runs login, refresh, CSRF, dispatcher, root listing,
and legacy search after a single hidden prompt. This is preferred over a
plaintext `.env` file or a persistent user environment variable.

The local ignored `.cloud_probe_account` may store the non-secret test email.
`cloud_probe roundtrip --confirm-write` performs the complete Phase 0 contract
test after one password prompt, so the application password never needs to be
persisted.

The Android application will store session secrets in
`flutter_secure_storage` backed by Android Keystore. SQLite and shared
preferences must not contain credentials, tokens, cookies, or authorization
headers.

## Live checklist

- [x] `cloud-win` password grant succeeds with an application password.
- [x] A normal password is rejected; a separate application password is required.
- [x] OAuth reports `expires_in=3600`; practical expiry still needs a timed test.
- [x] Refresh grant succeeds with `cloud-win` and rotates the refresh token.
- [ ] `cloud-android` is tested only if `cloud-win` refresh is unavailable.
- [x] CSRF endpoint works; write requests will confirm header requirements.
- [ ] All auth-expiry response variants are captured in sanitized fixtures.

## References

- [`CloudMailRu` authentication README](../../CloudMailRu/README.MD#авторизация)
- [`OAuthAppAuthStrategy.pas`](../../CloudMailRu/src/Infrastructure/Authentication/OAuthAppAuthStrategy.pas)
- [`WebDavMailRuCloud OAuthRefreshRequest.cs`](../../WebDavMailRuCloud/MailRuCloud/MailRuCloudApi/Base/Repos/MailRuCloud/Mobile/Requests/OAuthRefreshRequest.cs)
