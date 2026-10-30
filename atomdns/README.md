# atomdns

Configuration and WebUI of [jasonxtt/atomdns](https://github.com/jasonxtt/atomdns). Program binaries are
not kept here: they are assets of the atomdns GitHub Releases.

| Path | Content |
| --- | --- |
| `config/full/config_rust/` | The full configuration tree (source of both packages). |
| `config/full/config_rust.zip` | Fresh-install package: the tree plus `ui/main/` from the WebUI package below. `build_config_rust_zip.sh <atomdns-webui.tar.gz>` rebuilds it. |
| `config/incremental/config_rust_up.zip` | Incremental package the online update applies when the program requires a newer configuration schema. `build_config_rust_up.sh` builds it from the full tree. |
| `ui/atomdns-webui.tar.gz` | The WebUI package of the latest release (its files are `<config root>/ui/main/`). |

The update manifest of a release pins the incremental package by sha256, so a release points at it by
commit (`https://raw.githubusercontent.com/jasonxtt/file/<commit>/atomdns/config/incremental/config_rust_up.zip`),
never by branch, and a published package file must not be changed afterwards.

This directory was `rtdns/` until 2026-10-30. Released manifests pin the incremental package by commit, so their
`.../<commit>/rtdns/config/...` URLs keep working: they name the path as it was in that commit.
