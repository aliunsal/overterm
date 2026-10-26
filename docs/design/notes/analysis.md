# Notlar — analiz

Overterm'e Obsidian benzeri bir markdown not yönetimi; notlar iCloud ile
senkron. Obsidian'a entegre olmuyoruz: onun klasörünü, `.obsidian/`
ayarlarını ya da eklentilerini tanımıyoruz. Yaptığını kendimiz yapıyoruz.
Bu belge kodun bugünkü halini, iCloud seçeneklerini, Obsidian'dan neyi hangi
sırayla alacağımızı ve verilmesi gereken kararları toplar; uygulama planı
kararlardan sonra.

Satır numaraları 2026-10-24'teki `main`'e göre (`fe846e0`).

## Kısaca

- **iCloud'u iCloud Drive'daki düz bir klasörle yapmalıyız.** Kendi iCloud
  container'ımız ya da CloudKit için ücretli Apple Developer hesabı,
  provisioning profile, Developer ID imzası ve notarization gerekir.
  Uygulama bugün ad-hoc imzalı, notarize değil ve hiç entitlement'ı yok
  (`Scripts/make-app.sh:178`, README "Install"). Klasör yolunda senkronu
  macOS yapar. Bize dört iş kalır: bulutta duran dosyalar, koordineli
  okuma/yazma, canlı yeniden yükleme ve çakışmalar.
- **iPhone/iPad'de notlar Dosyalar uygulamasında görünür** (iCloud Drive ›
  Overterm Notes). Dosyalar `.md`'yi gösterir ama düzenleyemez; düzenlemek
  için dosyayı yerinde açan bir metin editörü gerekir (iA Writer, Runestone,
  Textastic gibi). Kendi iOS uygulamamız Apple Developer hesabı ister;
  kapsam dışı.
- **En pahalı kısım "tab".** Bugün her `Tab` bir terminal. Settings'in
  kullandığı yolu izlemek (strip'te bir öğe, gövdeyi kaplayan bir görünüm)
  ucuz ve güvenli.
- **Editörün temeli büyük ölçüde hazır.** Markdown tree-sitter grameri ve
  ⇧⌘V önizlemesi (`MarkdownRenderer`) var. Eksikler: wikilink'ler, not
  indeksi, git'e bağlı olmayan arama, canlı dış değişiklik takibi ve
  Obsidian'daki gibi "live preview".

## 1. Kodun bugünkü durumu

### Tab'lar

- `Tab.terminal` opsiyonel değil, `splits` bir `SplitTree<TerminalView>`;
  tek initializer `init(terminal:agent:)` (`Sources/Overterm/Tabs/Tab.swift:11`,
  `:13`, `:71-77`). Yani her `Tab` en az bir `TerminalView` sahibi.
- `TerminalWindowController` içinde yaklaşık 59 yer `.terminal`/`.terminals`
  varsayıyor: seçim (`showSelectedTab`, `:3048-3083`), odak
  (`focusSelectedTerminal`), arama çubuğu, gruplar (`stashGroup`, grup "+"),
  broadcast, kapatma onayı (`needsCloseConfirmation`), ajan taraması
  (`pollAgentDirectory`, `:1421-1450`), session.
- `TabKind` (`Tabs/TabKind.swift`) yalnızca strip'teki ikonu belirliyor
  (agent / server / shell / ssh); bir "içerik türü" kavramı yok.
- **Settings aslında bir `Tab` değil:**
  - `TabStore.settingsOpen` / `settingsShowing` bayrakları
    (`Tabs/TabStore.swift:48-52`); `store.selected` altta hâlâ terminal tab'ı.
  - Strip'te gruplardan sonra `SettingsTabItem` çiziliyor
    (`Tabs/TabBarView.swift:121-123`, `:425-455`).
  - Görünüm `buildLayout`'ta pencerenin `content`'ine eklenen, tab çubuğunun
    altındaki her şeyi (sidebar, terminal, editör, tarayıcı, diff) kaplayan
    bir `NSHostingView` (`TerminalWindowController.swift:604-616`).
  - Açma / gizleme / kapatma: `openSettings`, `showSettingsPage`,
    `hideSettingsPage`, `closeSettings` (`:2922-2951`); ⌘W
    `closeSelectedTab`'da erken dönüyor (`:3092`).
  - Session'a yazılmıyor; gruplar, ⌘1–9, Peek, overview, pin ve sürükleme
    dışında.
- Bugün tab başına terminal olmayan tek içerik tarayıcı:
  `browserWorkspaces[tab.id]`, ama yan sütunda.

### Session formatı

- `SessionState`: `tabs: [TabState]`, `selectedIndex`, `groups`
  (`Session/SessionState.swift:99-103`); `TabState` alanları `:8-32`.
- Synthesized `Codable`; bilinmeyen anahtarlar yok sayılır, eksik opsiyoneller
  `nil` olur, çözülemeyen dosya kenara alınır ve uygulama boş başlar
  (`Session/UnreadableFile.swift`).
- Sonuçları:
  - `TabState`'e yeni opsiyonel alan: eski sürüm yok sayar, ama o tab'ı
    `workingDirectory`'de bir shell olarak açar.
  - Mevcut bir enum'a yeni case: eski sürüm session'ın tamamını atar →
    MAJOR (`CLAUDE.md`, Versioning).
  - Yeni bir üst düzey anahtar: eski sürüm yok sayar; sorun yok.
- `restore` her kayıt için bir `TerminalView` kuruyor
  (`TerminalWindowController.swift:1221-1286`).

### Seçili tab'a bağlı olanlar

`showSelectedTab` içindeki `cwdSubscription` (`:3063-3082`) seçili tab'ın
`checkoutSource` köküne göre dosya ağacını, worktree'leri, diff'i, Overgit'i,
API workspace'ini ayarlıyor. Vault'u dosya ağacına kök olarak vermek
(`FileTreeModel.setRoot`, `Sidebar/FileTreeModel.swift:56-70`) sonraki tab
değişiminde ezilir; notların kendi `FileTreeModel`'i olmalı.

### Editör

- Her pencerede tek bir editör sütunu (`TerminalWindowController.swift:455-469`);
  tek bir `CodeTextView`, açık dosyaların text storage'ını değiştirerek
  gösteriyor (`Editor/EditorViewController.swift:292`). Sınıf tek instance
  varsaymıyor; ikinci bir instance mümkün.
- TextKit 1, bilinçli (`EditorViewController.swift:114-126`).
- `markdown` ve `markdown_inline` gramerleri ile Helix sorguları build'de var
  (`Scripts/build-treesitter.sh:31-32`, `Syntax/EditorLanguage.swift:154-159`);
  satır içi metin ve kod blokları injection ile.
- Boyama yalnızca renk, kalın, italik, altı/üstü çizili uygulayabiliyor
  (`paint`, `EditorViewController.swift:673-713`; `EditorTheme.Style`,
  `Editor/EditorTheme.swift:8-14`). Satır yüksekliği tek bir fonttan, sabit
  (`EditorLineHeight`, `Editor/EditorBuffer.swift:115-138`). Büyük başlıklar
  için ikisinin de değişmesi gerekir; gutter `lineRect(at:)` ile ölçtüğü için
  değişken yüksekliği izler (`Editor/EditorGutter.swift:87`).
- **Markdown önizlemesi zaten var**: `MarkdownRenderer.render`
  (`Editor/MarkdownPreview.swift:7-256`) `AttributedString(markdown:)` ile
  başlık (1.9×–0.95×), liste, kod bloğu, alıntı, tablo (`NSTextTable`) çiziyor;
  testleri `Tests/OvertermTests/MarkdownRendererTests.swift`.
  `MarkdownPreviewView` metnin **üstünde** açılıyor, yanında değil
  (`toggleMarkdownPreview`, `EditorViewController.swift:718-757`). Göreli
  linkler `onOpenFile` ile açılıyor; `[[wikilink]]` yok.
- Dış değişiklik: yalnızca mtime karşılaştırması
  (`EditorDocument.changedOnDisk`, `Editor/EditorDocument.swift:90-93`), yalnızca
  pencere öne gelince (`reloadIfChangedOnDisk`, `EditorViewController.swift:455-472`).
  Kaydedilmemiş buffer'da tek seçenek "Save Anyway" (`:924-935`); birleştirme
  yok. FSEvents editöre bir şey söylemiyor.
- Kaydetme atomik, symlink'ler üzerinden (`EditorDocument.swift:78-86`).
- `EditorDocument.load` 5 MB üstünü, binary'yi, UTF-8 olmayanı reddediyor.

### Arama ve seçiciler

- ⌘F ve dosya listesi git'e bağlı: `CheckoutSearch` `git ls-files` ve
  `git grep` çalıştırıyor; git olmayan bir vault'ta boş döner.
  `FuzzyMatch` sıralaması ve `ContentMatch` modeli olduğu gibi kullanılabilir.
- `EditorPicker` genel (`Editor/EditorPopups.swift:18-36`): placeholder,
  provider, choose, preview. Hızlı not geçişi için hazır.
- Dosyalar için ⌘P "Go to File" yok (yorumda geçiyor, keybinding'de yok).

### Diğer

- LSP'de markdown sunucusu yok; marksman tek bir `Spec` ile eklenebilir
  (`Editor/LSP/LanguageServers.swift:27-85`). Wikilink ve backlink'i kendimiz
  yapacağımız için gerekmiyor.
- Vim motoru dilden bağımsız; not editöründe de çalışır.
- `DirectoryWatcher` (FSEvents, recursive, 0.3 s) dosya ağacı, diff,
  Settings ve Keybindings tarafından kullanılıyor
  (`Sidebar/DirectoryWatcher.swift:22-46`).
- `Package.swift`'te SPM bağımlılığı yok; native kütüphaneler xcframework
  olarak script'lerle kuruluyor (GhosttyKit, TreeSitterKit). `WKWebView`
  yalnızca `Browser/` içinde.

## 2. iCloud

### Seçenekler

| | iCloud Drive'da klasör | Kendi container'ımız | CloudKit |
|---|---|---|---|
| Apple Developer hesabı | Gerekmez | Gerekir (ücretli) | Gerekir |
| Release değişikliği | Yok | Developer ID, notarization, profile | Aynı |
| Notlar diskte dosya mı | Evet | Evet | Hayır, kayıt olarak durur |
| iPhone tarafı | Dosyalar uygulaması | Ancak kendi iOS uygulamamızla | Ancak kendi iOS uygulamamızla |
| Minimum macOS | 13 | 13 | 14 (bizim minimumumuz 13) |

**Önerim: iCloud Drive'da klasör.** Ad-hoc imzalı bir uygulama iCloud
entitlement'larını taşıyamaz; diğer iki yol release sürecini baştan
değiştirir.

Varsayılan vault: `~/Library/Mobile Documents/com~apple~CloudDocs/Overterm Notes`
(Finder'da ve Dosyalar'da "iCloud Drive › Overterm Notes"). Kullanıcı başka
bir klasör seçebilir; iCloud dışındaki bir klasör yalnızca senkron olmaz.

### Bu Mac'te doğrulananlar (2026-10-24, macOS 26.7.1)

Entitlement'ı olmayan, ad-hoc derlenmiş küçük bir probe ile:

- iCloud Drive dosyalarının sync durumu okunabiliyor:
  `isUbiquitousItem`, `ubiquitousItemDownloadingStatus`,
  `ubiquitousItemHasUnresolvedConflicts`, `ubiquitousItemIsUploaded`.
- iCloud Drive'da örneklenen 45 dosyanın 38'i indirilmemiş ("Mac Saklama
  Alanını Optimize Et" açık). Bulutta duran dosya teorik değil.
- macOS 26'da `.icloud` placeholder dosyası yok (dataless dosyalar).

### Yapılması gerekenler

1. **Bulutta duran dosyalar.**
   - macOS 14 ve sonrası: "dataless" dosyalar. Okumak indirmeyi başlatır ve
     bitene kadar bekletir → ana thread'de asla okuma yok; dosya "bulutta"
     olarak gösterilir; `startDownloadingUbiquitousItem` çağrılır.
   - macOS 13 (bizim minimumumuz): gizli `.Not.md.icloud` placeholder
     dosyaları. Listede not gösterilir, placeholder gizlenir.
2. **Koordineli erişim.** Okuma ve yazma `NSFileCoordinator` üzerinden; sync
   daemon dosyayı yazarken yarım içerik okunmaz.
3. **Canlı değişiklik takibi.** Başka cihazdan gelen değişiklik pencere
   öndeyken de gelir. Vault `DirectoryWatcher` ile izlenir, değişmemiş
   buffer'lar yeniden yüklenir; değişmiş buffer çakışma olur.
4. **Çakışmalar.** İki cihaz aynı notu çevrimdışı düzenlerse iCloud birini
   kazanan seçer, diğerlerini `NSFileVersion` olarak saklar. Kullanıcıya
   "benimki / diğeri / yan yana karşılaştır" seçimi sunulur, çakışma çözüldü
   olarak işaretlenir.
5. **Testler gerçek iCloud'a dokunmaz.** Vault yolu `AppEnvironment`
   üzerinden gelir. Sync durumu bir protokolün arkasında durur; E2E'de
   sahtesi kullanılır.

### Spike'ta doğrulanacaklar

- Çakışma macOS 13'te ve 26'da aynı yoldan mı geliyor: `NSFileVersion`
  olarak mı, yoksa "Not 2.md" gibi bir kopya olarak mı?
- Koordineli okuma dataless bir dosyayı indiriyor mu, ne kadar bekletiyor?
- iPhone'da Dosyalar'dan yapılan bir düzenleme Mac'te açık nota ne kadar
  sürede ve hangi olaylarla geliyor?

## 3. Arayüz: "tab" nasıl olacak

| Seçenek | Ne | Maliyet ve risk |
|---|---|---|
| A. Gerçek tab türü | `Tab` genelleştirilir: terminal ya da notlar | En yüksek. Yaklaşık 59 `.terminal` kullanımı, gruplar, broadcast, Peek ve session formatı değişir; gerilemeye açık. |
| **B. Settings gibi bir çalışma alanı** | Strip'te bir "Notes" öğesi. Gövdeyi kaplayan görünümde vault ağacı, kendi editör instance'ı ve önizleme. | Orta; bu yolu Settings zaten açmış. Gruplar ve ⌘1–9 dışında kalır, ki notlar zaten bir checkout değil. Session'a yeni bir üst düzey anahtar eklenir. |
| C. Panel ve editör sütunu | Rail'de bir "Notes" paneli; notlar mevcut editör sütununda açılır (API client'ın izlediği yol) | En ucuzu ve terminalin yanında açık durur, ama "Obsidian gibi bir tab" hissini vermez. |

**Önerim B.** C'yi sonradan B'nin üstüne eklemek kolay, çünkü ikisi aynı
modeli ve aynı editörü kullanır.

## 4. Obsidian'dan ne alıyoruz

Aldığımız şey davranış ve not sözdizimi. Sözdizimini Obsidian'ınkiyle aynı
tutmayı öneriyorum: kullanıcının elindeki alışkanlık bu, notlar başka
markdown araçlarına taşınabilir kalır, kendi lehçemizi icat etmenin bir
getirisi yok.

### Sözdizimi

- Linkler: `[[Not]]`, `[[Not|takma ad]]`, `[[Not#Başlık]]`, `[[Not#^blok]]`;
  standart `[metin](yol.md)` linkleri de çözülür.
- Gömme: `![[Not]]`, `![[resim.png]]`.
- Etiketler: `#etiket`, `#iç/içe`; frontmatter'da `tags:`.
- YAML frontmatter (özellikler): `tags`, `aliases`, serbest alanlar.
- Görevler `- [ ]`, vurgu `==metin==`, yorum `%%metin%%`, callout
  `> [!note]`.

Bunların hiçbirini ne tree-sitter `markdown_inline` ne de
`AttributedString(markdown:)` tanıyor. Kod span'lerini ve kod bloklarını
atlayan kendi tarayıcımız gerekiyor (saf, birim testli); renderer ve editör
boyaması onu kullanır.

### Özellikler ve aşamalar

| Özellik | Obsidian'daki karşılığı | Aşama | Not |
|---|---|---|---|
| Vault ağacı: oluştur, yeniden adlandır, taşı, sil | File explorer | MVP | Kendi `FileTreeModel`'i |
| Editör ve yan önizleme | Source mode / Reading view | MVP | `MarkdownRenderer` genişletilir |
| Wikilink, `[[` yazınca otomatik tamamlama | Internal links | MVP | Not indeksi |
| Yeniden adlandırınca linkleri güncelleme | Automatically update internal links | MVP | Not indeksi; olmazsa linkler kırılır |
| Hızlı geçiş, yoksa yeni not | Quick switcher | MVP | `EditorPicker` |
| Backlink'ler | Backlinks | MVP | Not indeksi |
| Etiketler ve etiket listesi | Tags | MVP | |
| Tam metin arama | Search | MVP | Git'siz lister ve grep |
| Günlük not | Daily notes | MVP | |
| Resim yapıştırma / sürükleme → ekler klasörü | Attachments | MVP | |
| Live preview | Live Preview | 2 | TextKit 1; değişken satır yüksekliği, işaret gizleme |
| Gömme `![[…]]` | Embeds | 2 | |
| Callout, vurgu, yorum | | 2 | Renderer |
| Özellikler arayüzü | Properties | 2 | |
| Başlık ağacı | Outline | 2 | tree-sitter `symbols` |
| Link üstüne gelince önizleme | Page preview | 2 | |
| Şablonlar | Templates | 2 | |
| Linklenmemiş bahsetmeler | Unlinked mentions | 2 | |
| Notlar için sekmeler ve bölmeler | Tabs, splits | 2 | |
| Yer imleri | Bookmarks | 2 | |
| Görev kutucuğunu tıklayarak işaretleme | | 2 | |
| Graf görünümü | Graph view | 3 | Native çizim, force-directed yerleşim |
| Blok referansları `^id` | Block references | 3 | |
| Matematik, Mermaid | | 3 | JS gerekir: WKWebView ve vendored KaTeX/Mermaid |
| Dosya kurtarma | File recovery | 3 | iCloud'un `NSFileVersion`'ı ya da yerel snapshot |
| Canvas | Canvas | Açık | Ayrı, büyük bir iş |
| Eklentiler | Community plugins | Yok | CLAUDE.md: "no plugin slots" |
| Publish, Obsidian Sync | | Yok | Senkron iCloud Drive ile |

### Not indeksi

MVP'nin çoğu buna dayanıyor: isimden yola eşleme (büyük/küçük harf duyarsız;
isim birden fazla notta varsa yol ile), takma adlar, giden linkler,
backlink'ler, başlıklar, etiketler. Arka planda kurulur, watcher ile artımlı
güncellenir; saf parçaları birim testli.

İndeksleme buluttaki dosyaları indirir. Hepsini mi indireceğiz (backlink'ler
eksiksiz olur), yoksa yalnızca inmiş olanları mı indeksleyeceğiz (disk
kullanımı değişmez), bu bir seçim. Önerim hepsini indirmek: notlar küçük
dosyalar, eksik backlink ise sessizce yanlış bilgi.

### Live preview'ın maliyeti

`EditorTheme.Style`'a font boyutu, `EditorLineHeight`'a satır başına yükseklik
ve imlecin olmadığı satırlarda işaretleri gizleme (TextKit 1'de glyph
üretimi üzerinden). Bu kod editörünü de etkiler; markdown'a özel ayrı bir yol
olmalı. Bu yüzden 2. aşamada.

## 5. Overterm'e özgü taraf

`BrowserMCP` ve `APIMCP` gibi bir notlar MCP'si: Claude veya Codex vault'u
arar, notları okur, yeni not yazar. ⌘L ile bir not doğrudan bir ajana
gönderilir. Overterm'in not alanını Obsidian'dan ayıracak kısım bu; MVP'de.

## 6. Önerilen sıra

0. **Spike:** Bölüm 2'deki "doğrulanacaklar".
1. **MVP (MINOR sürüm):** Bölüm 3'teki çalışma alanı; Bölüm 4'teki MVP
   satırları; Bölüm 2'deki iCloud işleri (bulutta duran dosyalar,
   koordineli okuma/yazma, canlı yeniden yükleme, basit çakışma ekranı);
   Bölüm 5'teki notlar MCP'si ve ⌘L; session'da yeni bir üst düzey anahtar;
   birim testler ve geçici bir sahte vault üzerinde çalışan `notes` E2E
   senaryosu.
2. **Aşama 2:** Bölüm 4'teki "2" satırları; live preview başta.
3. **Aşama 3:** Graf, blok referansları, matematik/Mermaid, dosya kurtarma.

## Kararlar

Verilenler (2026-10-25):

- **Obsidian'a entegre olmuyoruz.** Obsidian'ın klasörü, `.obsidian/`
  ayarları ve eklentileri yok; davranışını ve sözdizimini kendimiz yapıyoruz.
  iPhone/iPad'de notlar Dosyalar uygulamasında.
- **Sync: iCloud Drive klasörü.** Apple Developer hesabı ve release
  değişikliği yok.
- **Arayüz: B, Settings gibi bir çalışma alanı.** Strip'te bir "Notes" öğesi,
  gövdeyi kaplayan görünüm; `Tab` modeline dokunulmaz.
- **MVP'deki editör: kaynak ve yan önizleme.** Live preview 2. aşamada.
- **Ajan entegrasyonu MVP'de:** notlar MCP'si ve ⌘L.
- **Vault'a ait ayarlar vault'un içinde:** günlük not klasörü, ekler
  klasörü, şablonlar; iCloud ile Mac'ler arasında senkron. Hangi klasörlerin
  vault olduğu makineye özel.
- **Birden fazla vault, MVP'den itibaren:** vault değiştirici ve vault başına
  durum (açık notlar, seçili not).
