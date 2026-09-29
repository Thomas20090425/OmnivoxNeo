# OmnivoxNeo - Cookie Persistence Debugging

## Changes Made

### 1. Enhanced Cookie Filter (`PortalTrustedStateVault.swift`)
- Added `"antixsrftoken"` to session cookie exclusion list (was missing the version without underscores)
- Added support for `.omnivox.ca` domain (parent domain for cross-institution cookies)
- Added DEBUG logging to show which cookies are being preserved

### 2. Cookie Restoration Timing (`AppModel.swift:start()`)
- Added 150ms delay after cookie restoration before first web request
- This ensures WebKit has fully integrated the cookies

### 3. Comprehensive Debug Logging
Added logging at three key points:

**When restoring cookies (app launch):**
```
🔐 Restoring trusted portal state: X cookies
  📦 cookieName = value... (domain: ..., expires: ...)
✅ Restored X trusted cookies to WebView
```

**When saving cookies (after successful auth):**
```
💾 Persisting trusted portal state: X of Y cookies
  💾 cookieName (domain: ...)
```

**When filtering cookies:**
```
✅ Preserving trusted cookie: cookieName (domain: ..., expires: ...)
```

## Expected Cookies for Trusted Device

After successful MFA verification, these cookies should be saved:

1. **DTKS** (.omnivox.ca) - Device trust key signature
2. **tkdzfxGtdu_dsUwGHCOya24lA** (.omnivox.ca) - Random-named trust token
3. **ParametresModule** (dawsoncollege.omnivox.ca) - Module parameters
4. **ckxiRRu9QiLyyMsKcb5DuPKQ** (dawsoncollege.omnivox.ca) - Random-named checksum

## Testing Steps

### 1. Fresh Login Test
1. **Clean slate**: Sign out completely in Neo
2. **First login**: Sign in with your credentials
3. **MFA verification**: Enter the 6-digit code
4. **Check console**: Look for `💾 Persisting trusted portal state:` - should show 4+ cookies
5. **Force quit**: Swipe up and kill Neo completely
6. **Relaunch**: Open Neo again
7. **Check console**: Look for `🔐 Restoring trusted portal state:` - should show the same cookies
8. **Expected**: Should go directly to schedule WITHOUT MFA prompt

### 2. Diagnostic Checks

If MFA is still required, check the console logs:

**Problem A: No cookies being saved**
```
💾 Persisting trusted portal state: 0 of X cookies
```
→ The filter is rejecting all cookies. Check cookie domains.

**Problem B: Cookies saved but not restored**
```
💾 Persisting trusted portal state: 4 cookies  ✅
🔐 Restoring trusted portal state: 0 cookies  ❌
```
→ Keychain load failed. Check keychain permissions.

**Problem C: Cookies restored but still prompted for MFA**
```
🔐 Restoring trusted portal state: 4 cookies  ✅
```
→ Server doesn't recognize the cookies. Possible causes:
  - WebKit didn't apply them before the request
  - Cookies expired
  - Server cleared the trust token server-side

### 3. AutoFill Test

The AutoFill button for verification codes from notifications:

**What was changed:**
- Created `VerificationCodeField.swift` - native UITextField wrapper
- Updated `VerificationView.swift` to use the native field on iOS

**Expected behavior:**
1. When you receive a code via OmniVox Mobile notification
2. Tap the verification code field in Neo
3. iOS should show a suggestion above the keyboard: "From OmniVox Mobile: 123456"
4. Tap the suggestion to auto-fill

**If not working:**
- Check that the notification contains a 6-digit numeric code
- iOS 12+ required for `.textContentType(.oneTimeCode)`
- Field must be focused for AutoFill to appear

## Known Issues

### Issue 1: VerificationCodeField.swift not in Xcode project
The new file was created but needs to be added to the Xcode project:
1. Open `OmnivoxNeo.xcodeproj` in Xcode
2. Right-click on the `Views` folder
3. Add Files → Select `VerificationCodeField.swift`

### Issue 2: Build may fail without Xcode
Command-line tools can't build Xcode projects. Open in Xcode to build.

## Next Steps

1. **Run the app** in Xcode or on device
2. **Check console logs** during login and app restart
3. **Report what you see**:
   - How many cookies are being saved?
   - How many are being restored?
   - What are their names and domains?

This will tell us exactly where the cookie persistence is failing.
