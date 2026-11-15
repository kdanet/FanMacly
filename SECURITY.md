# Security policy

FanMacly installs a privileged launchd helper that writes to the System Management Controller (SMC). Security problems in the helper, its XPC interface or the files it keeps under `/var/db/app.fanmacly` are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue**. Report it privately through GitHub: **Security → Report a vulnerability** on [the repository](https://github.com/kdanet/FanMacly/security/advisories/new).

Include the FanMacly version, your Mac model and macOS version, and steps to reproduce. You should get a reply within a week.

## Scope

In scope:

- a process that is not FanMacly, signed by the same team, being able to talk to the helper or make it write SMC keys;
- requests that make the helper write keys or values outside its validation (fan indices, RPM ranges, curves);
- file handling under `/var/db/app.fanmacly` (permissions, symlinks);
- ways to leave fans stopped or slow while the Mac overheats.

Out of scope: problems that need root access or a modified, re-signed build.

## Supported versions

Only the latest release gets security fixes.
