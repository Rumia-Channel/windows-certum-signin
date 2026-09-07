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

## Private repository について

この Action リポジトリを **private のまま** GitHub の別リポジトリから共有できる範囲には制限があります。GitHub の private action sharing は private repository 間向けで、public OSS repository から private action をそのまま `uses:` する用途には使えません。

公開 OSS (`Rumia-Channel/Dantalian` など) から直接使う場合は、この Action リポジトリ自体を public にするのが最も単純です。Action のソースコード内には秘密値を保存せず、認証情報は利用側 repository の Secrets / Environment にのみ置いてください。

private のまま使いたい場合は、利用側 workflow で別の認証情報を使ってこの repository を checkout し、local action として参照する方法もありますが、追加の PAT / GitHub App 管理が必要になるため通常は勧めません。

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
