# windows-certum-signin

Certum SimplySign のクラウド Code Signing 証明書を GitHub Actions の Windows runner から使うための composite action です。

SimplySign Desktop のインストール、TOTP 自動ログイン、証明書確認に加えて、署名対象をファイル種別から自動判定する dispatcher を持っています。必要なら signer を明示して手動指定もできます。

> [!WARNING]
> これは Certum / Asseco Data Systems 公式の CI API ではありません。SimplySign Desktop の GUI を自動操作してログインするため、SimplySign の UI や挙動が変わると修正が必要になる可能性があります。

## 対応する署名対象

| 種別 | Auto 対象 | 使用ツール |
| --- | --- | --- |
| Windows Authenticode | `.exe`, `.dll`, `.msi`, `.msix`, `.msixbundle`, `.appx`, `.appxbundle`, `.cab`, `.ocx`, `.cpl`, `.scr`, `.com` | `signtool.exe` |
| PowerShell | `.ps1`, `.psm1`, `.psd1`, `.ps1xml`, `.cdxml`, `.xaml` | `Set-AuthenticodeSignature` |
| Java archives | `.jar`, `.war`, `.ear` | `jarsigner` + SimplySign PKCS#11 |
| NuGet | `.nupkg` | `dotnet nuget sign` |
| ClickOnce / VSTO manifests | `.manifest`, `.application`, `.vsto` | `Mage.exe` |
| Office VBA | Microsoft Office SIP 対応形式 | Microsoft Office SIP + x86 `signtool.exe` / `offsign.bat` |
| Adobe AIR | `.airi`, `.ane`, `.airn` | AIR SDK `adt` |

Driver `.sys` は意図的に非対応です。`.cat` は driver catalog と区別できないため Auto では拒否します。非 driver catalog を署名する必要がある場合だけ `authenticode::path.cat` と明示してください。この Action は WHQL / attestation signing / Hardware Dev Center の代替ではありません。

既存 `.air` は ADT で再署名できないため Auto/Manual とも拒否します。初回署名は `.airi` から `.air` を生成してください。

## 必要な値

### `CERTUM_USERNAME`

SimplySign のログイン ID / ユーザー名です。

### `CERTUM_OTP_URI`

SimplySign の TOTP seed を含む完全な `otpauth://...` URI を丸ごと保存します。

**これは長期的な認証秘密情報です。** README、workflow、ログ、Artifact に入れず、GitHub Secret / Environment Secret として保存してください。

### `CERTUM_KEY_ID`

Code Signing 証明書の SHA-1 thumbprint です。秘密情報ではありません。

SimplySign Desktop にログインした Windows PC で確認できます。

```powershell
Get-ChildItem Cert:\CurrentUser\My |
  Where-Object { $_.EnhancedKeyUsageList.ObjectId.Value -contains '1.3.6.1.5.5.7.3.3' } |
  Select-Object Subject, Thumbprint, NotAfter, HasPrivateKey
```

## 最小構成: 自動振り分け

`files` に署名対象を並べるだけです。`signer` の既定値は `auto` です。

```yaml
- name: Sign release artifacts
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}
    files: |
      dist\MyApp.exe
      scripts\install.ps1
      build\MyApp.jar
      packages\MyLibrary.*.nupkg
```

この場合は拡張子からそれぞれ Authenticode / PowerShell / jarsigner / NuGet に振り分けます。

## 手動指定

### `files` 全体を同じ signer に固定

```yaml
- name: Force Authenticode
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}
    signer: authenticode
    files: |
      dist\custom-extension.bin
```

### ファイルごとに signer を指定

`targets` は 1 行につき `signer::path/glob` です。prefix を省略した行は `auto` 扱いです。

```yaml
- name: Sign mixed artifacts
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}
    targets: |
      authenticode::dist\MyApp.exe
      powershell::scripts\*.ps1
      java::build\*.jar
      nuget::packages\*.nupkg
      clickonce::publish\MyApp.application
      office-vba::macros\Workbook.xlsm
      air::build\MyApp.airi=>dist\MyApp.air
```

指定できる signer 名:

- `auto`
- `authenticode` (`signtool`, `windows` も可)
- `powershell` (`ps`)
- `java` (`jar`, `jarsigner`)
- `nuget` (`nupkg`)
- `clickonce` (`mage`)
- `office-vba` (`office`, `vba`)
- `air` (`adt`)

`files` と `targets` は併用できます。

## Tauri v2

Tauri は bundle の生成途中で application EXE と installer を適切な順序で署名するため、Tauri 自身に署名させるのが安全です。この Action では `files` / `targets` を指定せず SimplySign を使用可能な状態までセットアップし、Tauri の `bundle.windows` 設定に証明書 thumbprint を渡します。

```yaml
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
          timestampUrl = "http://time.certum.pl"
        }
      }
    } |
      ConvertTo-Json -Depth 10 |
      Set-Content src-tauri/tauri.signing.conf.json

- name: Build and sign Tauri
  run: pnpm tauri build --config src-tauri/tauri.signing.conf.json
```

Tauri に署名させる場合はこの Action の `files` を指定しないでください。bundle 完成後に中身だけ再署名する順序事故や二重署名を避けられます。

## Java / JAR / WAR / EAR

Java signer は Certum が案内している SimplySign PKCS#11 構成を利用します。`C:\Windows\System32\SimplySignPKCS.dll` を使い、証明書 thumbprint と一致する PKCS#11 alias を `keytool` から探索して `jarsigner` を実行します。

GitHub hosted `windows-latest` には通常 JDK がありますが、Java バージョンを固定したい場合は先に `actions/setup-java` を実行してください。

SimplySign アカウントに virtual card が 1 枚なら通常 `java-pkcs11-slot: 0` のままで構いません。複数カードがある場合は slot を明示できます。

```yaml
with:
  java-pkcs11-slot: 0
  files: build\app.jar
```

## NuGet

`.nupkg` は Windows certificate store の証明書を `dotnet nuget sign` から使用します。.NET 9 以降では SHA-256 certificate fingerprint を自動計算して使用し、古い SDK では必要に応じて SHA-1 thumbprint を使用します。署名後は `dotnet nuget verify --all` で検証します。

## ClickOnce / VSTO

`.manifest` は `Mage.exe` で署名します。

`.application` / `.vsto` を指定した場合、deployment manifest 内からローカルの application manifest を検出できれば次の順で処理します。

1. application manifest を署名
2. deployment manifest を `Mage -Update ... -AppManifest ...` で更新
3. deployment manifest を署名
4. `Mage -Verify` で検証

application manifest がローカルに見つからない場合は deployment manifest だけを署名し、warning を出します。

## Office VBA

Microsoft の Office Subject Interface Package (SIP) を利用します。Office 本体は不要ですが、**x86 Office SIP package を事前に展開**しておく必要があります。

Microsoft Download Center:

- `Microsoft Office Subject Interface Packages for Digitally Signing VBA Projects`
- https://www.microsoft.com/en-us/download/details.aspx?id=56617

展開したディレクトリには少なくとも次が必要です。

```text
msosip.dll
msosipx.dll
vbe7.dll
offsign.bat
offclearsig.exe
```

Action へそのディレクトリを渡します。

```yaml
- name: Sign Office VBA
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}
    office-sips-path: tools\OfficeSips-x86
    files: macros\Workbook.xlsm
```

Action は x86 SIP を登録し、Microsoft の `offsign.bat` と x86 SignTool を使います。Microsoft Access VBA は SignTool + Office SIP が対応していないため対象外です。

Auto 対象の Office VBA 形式:

```text
.xla .xls .xlt
.pot .ppa .pps .ppt
.mpp .mpt .pub
.vdw .vdx .vsd .vss .vst .vsx .vtx
.doc .dot .wiz
.xlam .xlsb .xlsm .xltm
.potm .ppam .ppsm .pptm
.vsdm .vssm .vstm
.docm .dotm
```

## Adobe AIR

AIR SDK の `adt` が必要です。`adt` を PATH に入れる、`AIR_HOME` を設定する、または `air-adt-path` を指定してください。

`.airi` は同名の `.air` へ署名します。

```yaml
with:
  files: build\MyApp.airi
```

出力先を明示する場合:

```yaml
with:
  targets: |
    air::build\MyApp.airi=>dist\MyApp.air
```

`.ane` / `.airn` は output 指定がなければ一時ファイルへ署名後、元ファイルを置き換えます。既存 `.air` の再署名は ADT の仕様上行いません。

## セットアップだけ行う

`files` と `targets` を両方省略すると、SimplySign Desktop のインストール、ログイン、証明書確認だけ行います。その後の step で Tauri や独自コマンドから証明書を使えます。

```yaml
- name: Setup SimplySign only
  uses: Rumia-Channel/windows-certum-signin@main
  with:
    certum-username: ${{ secrets.CERTUM_USERNAME }}
    certum-otp-uri: ${{ secrets.CERTUM_OTP_URI }}
    certum-key-id: ${{ vars.CERTUM_KEY_ID }}
```

## Inputs

| Input | 必須 | Default | 内容 |
| --- | --- | --- | --- |
| `certum-username` | Yes | - | SimplySign login/user ID |
| `certum-otp-uri` | Yes | - | 完全な TOTP `otpauth://` URI |
| `certum-key-id` | Yes | - | Code Signing certificate SHA-1 thumbprint |
| `files` | No | empty | 自動/一括 signer 用 path / glob |
| `signer` | No | `auto` | `files` 全体に適用する signer |
| `targets` | No | empty | `signer::path` 形式の個別指定 |
| `timestamp-url` | No | `http://time.certum.pl` | timestamp server |
| `simplysign-url` | No | pinned MSI URL | SimplySign Desktop x64 MSI |
| `java-pkcs11-slot` | No | `0` | SimplySign PKCS#11 slotListIndex |
| `java-pkcs11-pin` | No | `12345678` | PKCS#11 storepass に渡す非空値 |
| `office-sips-path` | No | empty | 展開済み x86 Office SIP directory |
| `air-adt-path` | No | auto | AIR SDK ADT executable |
| `capture-diagnostics` | No | `false` | SimplySign 認証画面の診断 capture |

## Outputs

- `certificate-subject`
- `certificate-thumbprint`

## Security notes

- `CERTUM_OTP_URI` の `secret=` は TOTP master seed です。漏洩した場合は SimplySign access の再 provisioning を行って無効化してください。
- signing job は fork PR / `pull_request` ではなく tag/release 等に限定することを推奨します。
- GitHub Environment の required reviewers を利用すると署名鍵の使用を承認制にできます。
- `capture-diagnostics=true` は通常使用しないでください。
- 公開 Action を利用側から参照するときも、安定運用では `@main` ではなく確認済み commit SHA または管理された release tag (`@v1`) への固定を推奨します。
- Certum Open Source Code Signing in the Cloud には月間署名回数の制限があります。不要な CI run で署名しない構成にしてください。

## References

- Certum Code Signing in the Cloud / SignTool + jarsigner manual
  - https://files.certum.eu/documents/manual_en/CS-Code_Signing_in_the_Cloud_Signtool_jarsigner_signing.pdf
- Microsoft Office Subject Interface Packages
  - https://www.microsoft.com/en-us/download/details.aspx?id=56617
- Microsoft Mage.exe
  - https://learn.microsoft.com/en-us/dotnet/framework/tools/mage-exe-manifest-generation-and-editing-tool
- Microsoft `Set-AuthenticodeSignature`
  - https://learn.microsoft.com/powershell/module/microsoft.powershell.security/set-authenticodesignature
- Microsoft `dotnet nuget sign`
  - https://learn.microsoft.com/dotnet/core/tools/dotnet-nuget-sign
- AIR SDK ADT code signing options
  - https://airsdk.dev/docs/building/air-developer-tool/option-sets/code-signing-options

## Attribution

SimplySign の自動ログイン実装は `dismine/windows-app-signing-setup-action` の MIT licensed implementation と、Takuya Matsuyama 氏の SimplySign automation の記事を参考にしています。詳細は [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) を参照してください。

## License

MIT
