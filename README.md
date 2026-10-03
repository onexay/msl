# msl

MSL runs Linux distributions on Apple silicon Macs with WSL-compatible commands and distribution images.

Requires macOS 27 or later.

## Install

```console
$ curl -fsSL https://raw.githubusercontent.com/onexay/msl/main/install.sh | sh
```

Install Ubuntu and open a shell:

```console
$ msl --install Ubuntu
$ msl
```

## Documentation

Read the [MSL documentation](https://onexay.github.io/msl-docs/) for installation options, [commands](https://onexay.github.io/msl-docs/docs/overview/basic-commands/), [VS Code setup](https://onexay.github.io/msl-docs/docs/tutorials/msl-vscode/), configuration and troubleshooting.

For development, see [Contributing](CONTRIBUTING.md) and the [architecture notes](docs/architecture.md).

## License

MSL is independent of Microsoft and Apple. It is licensed under the [Apache License 2.0](LICENSE). See [NOTICE](NOTICE) and [third-party notices](docs/third_party_notices.md).
