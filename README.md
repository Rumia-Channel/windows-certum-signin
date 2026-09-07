# windows-certum-signin

Certum SimplySign のクラウド Code Signing 証明書を GitHub Actions の Windows runner から使うための composite action です。

この Action は次を行います。

1. SimplySign Desktop をインストール
2. 自動ログイン向けのレジストリ設定
3. `otpauth://` URI から TOTP を生成
4. SimplySign Desktop のログイン画面へユーザー名と TOTP を投入
5. 指定した証明書の SHA-1 thumbprint が Windows 証明書ストアに現れるまで待機
6. 指定された EXE / DLL / MSI 等を `signtool.exe` で SHA-256 + RFC 3161 timestamp 署名
7. `signtool verify /pa /v` で署名を検証

> [!WARNING]
> これは Certum / Asseco Data Systems 公式の CI インターフェースではありません。SimplySign Desktop の GUI を自動操作する方式なので、SimplySign の UI や挙動が変わると修正が必要になる可能性があります。

## 必要な値

### `CERTUM_USERNAME`

SimplySign のログイン ID / ユーザー名。

### `CERTUM_OTP_URI`

SimplySign の TOTP seed を含む完全な `otpauth://...` URI。

**これは長期的な認証秘密情報です。パスワードと同等以上に扱ってください。** README、workflow、ログ、Artifact には絶対に入れず、GitHub Environment Secret / Repository Secret として保存します。

SimplySign の初回 activation / access recovery で表示される QR code は標準の `otpauth://` 情報を含みます。CI 化する場合は、その provisioning 時に TOTP 対応 password manager 等にも登録して URI を安全に保管しておく必要があります。

既に activation 済みの場合、CI 用 URI を取得する目的だけで安易に `Regain access` を繰り返さないでください。再 provisioning により既存アクセスの状態が変わる可能性があります。

### `CERTUM_KEY_ID`

Code Signing 証明書の SHA-1 thumbprint。これは秘密情報ではありませんが、設定値として Environment Variable / Secret に置くと扱いやすいです。

SimplySign Desktop へログインした Windows PC で例:

```powershell
Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.EnhancedKeyUsageList.FriendlyName -contains 'Code Signing' } |
  Select-Object Subject, Thumbprint, NotAfter
```

## 推奨 Secrets / Variables

署名専用の GitHub Environment、例 `code-signing` を作り、次を保存します。

Secrets:

- `CERTUM_USERNAME`
- `CERTUM_OTP_URI`

Variables または Secrets:

- `CERTUM_KEY_ID`

可能なら Environment に required reviewers を設定し、署名ジョブを release/tag のみに限定してください。fork PR / `pull_request` から署名 secrets を使用しないでください。

## 使用例

```yaml
name: Build and sign Windows release

on:
  workflow_dispatch:
  push:
    tags:
      - 'v*'

permissions:
  contents: read

jobs:
  build-and-sign:
    runs-on: windows-latest
    environment: code-signing

    steps:
      - uses: actions/checkout@v6

      # ここで通常どおり build
      - name: Build
        shell: pwsh
        run: |
          # cargo build --release
          # dotnet publish ...
          # npm run build ...

      - name: Sign Windows binaries
        uses: Rumia-Channel/windows-certum-signin@main
        with:
          certum-username: ${{ secrets.CERTUM_USERNAME }}
          certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
          certum-key-id: ${{ vars.CERTUM_KEY_ID }}
          files: |
            dist\MyApp.exe
            dist\*.dll

      - name: Upload signed files
        uses: actions/upload-artifact@v5
        with:
          name: windows-signed
          path: dist\
```

安定運用では `@main` より、確認済み commit SHA または自分で管理する release tag (`@v1`) に固定する方が安全です。

### セットアップだけ行う

`files` を省略すると SimplySign のセットアップ・ログイン・証明書確認だけ行い、その後の step で自分で `signtool` を呼べます。

```yaml
- name: Setup SimplySign
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}

- name: Custom signing
  shell: pwsh
  run: |
    # signtool sign ...
```

## Tauri で使う

Tauri v2 には Windows Code Signing の仕組みがあるため、Tauri プロジェクトではこの Action に `files` を渡して完成後のファイルを個別署名するより、**この Action では SimplySign のセットアップだけを行い、実際の署名タイミングは Tauri に任せる**方法を推奨します。

Tauri の Windows signing 設定は次の 3 値を使用します。

- `bundle.windows.certificateThumbprint`: `CERTUM_KEY_ID` と同じ SHA-1 thumbprint
- `bundle.windows.digestAlgorithm`: `sha256`
- `bundle.windows.timestampUrl`: Certum の RFC 3161 timestamp server

この方法なら、Tauri の bundle pipeline 内でアプリ本体の EXE を署名してから Windows installer を生成・署名するため、**installer の外側だけ署名されて中に unsigned EXE が入る**ような順序ミスを避けられます。

### GitHub Actions 例

```yaml
name: Build signed Tauri app

on:
  workflow_dispatch:
  push:
    tags:
      - 'v*'

permissions:
  contents: read

jobs:
  build-windows:
    runs-on: windows-latest
    environment: code-signing

    steps:
      - uses: actions/checkout@v6

      # Node / Rust / pnpm 等のセットアップはプロジェクトに合わせて追加

      - name: Setup Certum SimplySign
        uses: Rumia-Channel/windows-certum-signin@main
        with:
          certum-username: ${{ secrets.CERTUM_USERNAME }}
          certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
          certum-key-id: ${{ vars.CERTUM_KEY_ID }}

      - name: Create Tauri signing config
        shell: pwsh
        env:
          CERTUM_KEY_ID: ${{ vars.CERTUM_KEY_ID }}
        run: |
          @{
            bundle = @{
              windows = @{
                certificateThumbprint = $env:CERTUM_KEY_ID
                digestAlgorithm = "sha256"
                timestampUrl = "http://timestamp.certum.pl"
              }
            }
          } |
            ConvertTo-Json -Depth 10 |
            Set-Content -Encoding utf8 src-tauri/tauri.signing.conf.json

      - name: Build and sign Tauri app
        shell: pwsh
        run: pnpm tauri build --config src-tauri/tauri.signing.conf.json
```

`--config` で渡した設定は Tauri の通常の設定へ JSON Merge Patch としてマージされるため、既存の `tauri.conf.json` を CI 専用の thumbprint で書き換える必要はありません。

npm を使う場合は例えば次のように置き換えられます。

```powershell
npm run tauri build -- --config src-tauri/tauri.signing.conf.json
```

Cargo CLI を直接使う場合:

```powershell
cargo tauri build --config src-tauri/tauri.signing.conf.json
```

### `tauri.windows.conf.json` に固定設定を書く場合

`CERTUM_KEY_ID` を repository 内に置いても問題ない場合は、Tauri の platform-specific config を使う方法もあります。SHA-1 thumbprint 自体は秘密情報ではありません。

`src-tauri/tauri.windows.conf.json`:

```json
{
  "bundle": {
    "windows": {
      "certificateThumbprint": "YOUR_CERTIFICATE_SHA1_THUMBPRINT",
      "digestAlgorithm": "sha256",
      "timestampUrl": "http://timestamp.certum.pl"
    }
  }
}
```

このファイルは Windows build 時に通常の Tauri 設定へ自動的にマージされます。

> [!NOTE]
> Tauri に署名を任せる場合、この Action の `files` input は指定しません。`files` を指定すると Action 側でも署名処理が走るため、Tauri の bundling 前後で意図しない二重署名になる可能性があります。

参考:

- [Tauri v2 - Windows Code Signing](https://v2.tauri.app/ja/distribute/sign/windows/)
- [Tauri v2 - Configuration Files](https://v2.tauri.app/ja/develop/configuration-files/)

## Inputs

| Input | 必須 | Default | 内容 |
| --- | --- | --- | --- |
| `certum-username` | Yes | - | SimplySign login/user ID |
| `certum-otp-uri` | Yes | - | TOTP `otpauth://` URI |
| `certum-key-id` | Yes | - | Code Signing certificate SHA-1 thumbprint |
| `files` | No | empty | 改行または `;` 区切りの署名対象 path / glob |
| `timestamp-url` | No | `http://timestamp.certum.pl` | RFC 3161 timestamp server |
| `simplysign-url` | No | pinned MSI URL | SimplySign Desktop x64 MSI |
| `capture-diagnostics` | No | `false` | 認証失敗時の画面 capture。アカウント情報が映る可能性あり |

## Outputs

- `certificate-subject`
- `certificate-thumbprint`

## Security notes

- `CERTUM_OTP_URI` の `secret=` は TOTP の master seed です。漏洩したら SimplySign access を再 provisioning して無効化してください。
- signing job は PR ではなく tag/release 等に限定してください。
- GitHub Environment の required reviewer を推奨します。
- `capture-diagnostics=true` は通常使用しないでください。
- Action / third-party Actions は commit SHA pinning を推奨します。
- timestamp を付けた署名は、証明書失効等の条件を除き、証明書の有効期限後も署名時点を検証するために使われます。

## Attribution

実装は `dismine/windows-app-signing-setup-action` の MIT licensed implementation と、Takuya Matsuyama 氏の SimplySign automation の記事を参考にしています。詳細は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照してください。

## License

MIT
