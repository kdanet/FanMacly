# Contributing to FanMacly

Thanks for your interest! Bug reports, hardware test results from other Mac models, translations and pull requests are all welcome.

## Before you start

- FanMacly controls real hardware from a root helper. Changes to `Sources/FanMaclyCore` and `Sources/FanMaclyHelper` must keep the safety rules in [docs/control-policy.md](docs/control-policy.md): hot readings always win over a profile, and fans must always end up back with macOS.
- For anything bigger than a small fix, please open an issue first so we can agree on the approach.
- The interface is in Russian. Localization (a String Catalog with English as the second language) is a welcome contribution.

## Building

You need a Mac with Apple Silicon and the full Xcode 27 (macOS SDK 27, Swift 6.4).

```sh
bash scripts/check.sh        # build everything and run the unit tests
bash scripts/build.sh        # ad-hoc build in build/FanMacly.app (monitoring only)
bash scripts/preview.sh --panel-window   # isolated UI preview: own bundle ID, no helper
```

To test fan control you need a build signed with your own Apple Development or Developer ID certificate:

```sh
SIGN_IDENTITY='Apple Development: Your Name (XXXXXXXXXX)' bash scripts/build.sh
```

The helper accepts connections only from an app with the same identifier, signed by the same team, so it works with your own certificate without code changes.

## Forks and identifiers

The bundle and launchd identifiers are `app.fanmacly` (app), `app.fanmacly.helper` (helper), `app.fanmacly.controls` (widget extension) and `app.fanmacly.preview` (preview copy). If you ship a fork, change them so it can't collide with FanMacly on the same Mac:

- `HelperIdentity` in `Sources/FanMaclyCore/HelperProtocol.swift`;
- `Resources/Info.plist`, `Resources/app.fanmacly.helper.plist` (also rename the file) and `Controls.project.yml` (then run `xcodegen`);
- the `--identifier` values in `scripts/build.sh` and the bundle ID in `scripts/preview.sh`;
- the paths under `/var/db/app.fanmacly` in `Sources/FanMaclyHelper/main.swift`.

## Testing on hardware

The diagnostic tools only read registers and are safe to run:

```sh
.build/debug/fanmacly-probe --watch=60   # FnMd/Ftst/targets/temperatures, one line per second
bash scripts/soak-test.sh 30             # 30 minutes of observation
```

When you report a bug, please attach the output of **Settings → Diagnostics → Copy report** (Настройки → Диагностика → Скопировать отчёт) and the helper log:

```sh
/usr/bin/log show --last 30m --predicate 'subsystem == "app.fanmacly.helper"'
```

## Pull requests

- Keep changes focused. Add or update tests in `Tests/` for any change in `FanMaclyCore`.
- Run `bash scripts/check.sh` before opening the PR.
- Update [CHANGELOG.md](CHANGELOG.md) for user-visible changes.
- If you change the XPC messages, the status format or the launchd plist, bump `HelperIdentity.protocolVersion`.

By contributing you agree that your work is released under the [MIT License](LICENSE).
