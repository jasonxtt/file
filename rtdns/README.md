# rtdns

Configuration and WebUI of [jasonxtt/rtdns](https://github.com/jasonxtt/rtdns). Program binaries are
not kept here: they are assets of the rtdns GitHub Releases.

| Path | Content |
| --- | --- |
| `config/full/config_rust/` | The full configuration tree (source of both packages). |
| `config/full/config_rust.zip` | Fresh-install package: the tree plus `ui/main/` from the WebUI package below. `build_config_rust_zip.sh <rtdns-webui.tar.gz>` rebuilds it. |
| `config/incremental/config_rust_up.zip` | Incremental package the online update applies when the program requires a newer configuration schema. `build_config_rust_up.sh` builds it from the full tree. |
| `ui/rtdns-webui.tar.gz` | The WebUI package of the latest release (its files are `<config root>/ui/main/`). |

The update manifest of a release pins the incremental package by sha256, so a release points at it by
commit (`https://raw.githubusercontent.com/jasonxtt/file/<commit>/rtdns/config/incremental/config_rust_up.zip`),
never by branch, and a published package file must not be changed afterwards.
