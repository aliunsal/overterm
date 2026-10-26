# Notlar — implementasyon planı

`analysis.md`'deki kararlar üzerine: iCloud Drive'da düz klasörler, Settings
gibi bir çalışma alanı (B), kaynak ve yan önizleme, birden fazla vault, vault'a
ait ayarlar vault'un içinde, ajan entegrasyonu MVP'de.

Satır numaraları 2026-10-25'teki `main`'e göre (`fe846e0`).

## 1. Parçalar

Yeni klasör `Sources/Overterm/Notes/`. Saf olanlar birim testli; dosya ve
iCloud'a dokunanlar bir protokolün arkasında, testlerde sahtesiyle.

| Parça | Ne yapar | Saf mı |
|---|---|---|
| `NoteSyntax` | Bir notun metninden wikilink, gömme, etiket, frontmatter, görev, vurgu, yorum, callout aralıklarını çıkarır; kod bloklarını ve kod span'lerini atlar | Evet |
| `NoteLinks` | `[[hedef]]`'i bir dosyaya çözer (isimle, büyük/küçük harf duyarsız; isim birden fazla notta varsa yolla); yeniden adlandırmada hangi dosyada hangi linkin değişeceğini planlar | Evet |
| `NoteIndex` | Vault'un indeksi: isim → dosya, takma adlar, giden linkler, backlink'ler, başlıklar, etiketler, aramak için metin. Arka planda kurulur, watcher olaylarıyla artımlı güncellenir | Hayır |
| `CloudFiles` | Protokol: indirme durumu, indirmeyi başlatma, koordineli okuma/yazma, çakışan sürümler. Gerçeği `FileManager` + `NSFileCoordinator` + `NSFileVersion`; macOS 13'ün `.X.md.icloud` placeholder'larını notun kendisine eşler | Hayır (sahtesi var) |
| `NoteVaults` | Makinenin vault listesi ve son açılan: `supportDirectory/vaults.json` (`snippets.json` gibi). Ayar değil: şemada liste ya da klasör yolu türü yok (`SettingsSchema.swift:59-67`) | Hayır |
| `VaultConfig` | Vault'a ait ayarlar: `<vault>/.overterm/notes.json` (günlük not klasörü ve formatı, ekler klasörü, şablonlar klasörü, yeni notların klasörü). Yoksa varsayılanlar. Ağaçta gizli | Hayır |
| `VaultModel` | Bir vault: kendi `FileTreeModel`'i, `DirectoryWatcher`'ı, indeksi | Hayır |
| `NotesWorkspace` | Pencere başına: açık vault, vault değiştirici, vault başına açık notlar ve seçili not | Hayır |
| `NotesViewController` | Overlay: solda vault değiştirici, ağaç, etiketler; ortada ikinci `EditorViewController`; sağda `MarkdownPreviewView` ve backlink'ler | Hayır |
| `NotesMCP` | Mevcut MCP sunucusunda `notes_` önekli araç grubu | Hayır |
| `TerminalWindowController+Notes` | Overlay'in pencereye bağlanması, menü, palet, session, ajana sorma | Hayır |

Varsayılan vault yeri `AppEnvironment` üzerinden: gerçek çalışmada
`~/Library/Mobile Documents/com~apple~CloudDocs/Overterm Notes`, izole
çalışmada `supportDirectory/Notes`. İlk açılışta klasör kendiliğinden
yaratılmaz: "iCloud Drive'da oluştur" ya da "Klasör seç" sorulur, çünkü
iCloud Drive'a yazmak kullanıcının bütün cihazlarına gider.

## 2. Mevcut koda dokunulacak yerler

### Overlay'ler sırayla

Bugün tek overlay varsayılıyor: `TabStore.settingsOpen`/`settingsShowing`
(`Tabs/TabStore.swift:48-52`); ⌘W (`TerminalWindowController.swift:3092`),
strip'te seçili görünme (`Tabs/TabBarView.swift:257`), tab değişince gizleme
(`TerminalWindowController.swift:193-202`) yalnızca Settings'i biliyor.
`showSettingsPage` Notes'u, Notes da Settings'i gizlemeli.

Önerim: `settingsShowing` yerine `showing: WorkspaceOverlay?` (`settings`,
`notes`), açık olanlar için ayrı bayraklar. Davranış değişmez; `settings`
E2E senaryosu yeşil kalır.

Bilinen, bugün de var olan davranışlar (değiştirmiyoruz, Notes da miras
alır): palet, overview ve Peek overlay'i kontrol etmiyor ve kapanırken
terminale odak veriyor; ⌘1–9 overlay açıkken muhtemelen bir şey yapmıyor
(koddan çıkarım, test edilmedi).

### İkinci editör

`EditorViewController` pencereye gevşek bağlı; LSP ve teşhisler birden fazla
editörü zaten destekliyor (`EditorViewController+Intelligence.swift:38-73`,
`LanguageServer.swift:375-434`). Gerekenler:

- Başlıktaki zoom ve ✕ düğmelerini gizleme seçeneği; `onToggleZoom` yoksa ⇧⎋
  yutulmasın.
- Metin değişince haber veren bir callback (`onTextChange`): önizleme yanda,
  editörün dışında duracak. Bugün editör, metin görünümünün tek delegesi
  (`EditorViewController.swift:156`).
- Ayar ve tema değişikliklerini ikinci editöre de iletmek: editör
  `Settings.shared.changes`'i kendisi dinlemiyor; pencere yalnızca kendi
  editörüne iletiyor (`TerminalWindowController.swift:2881`, `:2911`).
- Kaydedilmemiş değişiklik kontrolleri iki editörü de görmeli: pencereyi
  kapatma (`:3220`), son tab (`:2983`), uygulamadan çıkma
  (`AppDelegate.swift:49`) bugün yalnızca `editor`'a bakıyor.
- Dosya erişimi için bir seam: `EditorBuffer` kendi `EditorDocument`'ını
  yaratıyor (`EditorBuffer.swift:8`), yazma tek satır
  (`EditorDocument.swift:82`). Notlarda yazma koordineli olacak; kod
  editörünün davranışı değişmez.
- Notlar için git gutter kapalı: her açma ve kaydetmede bir `git` süreci
  çalışıyor (`EditorViewController+Navigation.swift:405-460`).
- Tamamlama için bir kaynak kancası. `[[` bugün çalışmaz: `[` otomatik `[]`
  oluyor (`EditCommands.swift:259`), boşluk ve tire listeyi kapatıyor
  (`+Editing.swift:306`), boş sorguda yalnızca LSP adayları çıkıyor (`:309`).
  Kanca: tetikleyici `[[`, sorguda boşluk serbest, adaylar indeksten, kabulde
  köşeli parantezlerin içi değişir.

Okuma ana thread'de ve senkron (`EditorDocument.swift:27-61`). Notlar
katmanı bir notu editöre ancak indirildikten sonra verir; indirilirken
"indiriliyor" gösterir. Böylece editörün okuması değişmeden kalır.

### Önizleme

Notlar kendi `MarkdownPreviewView`'ını editörün yanına koyar; kod editöründeki
⇧⌘V aynen kalır. `MarkdownRenderer`'a parse'tan önce bir geçiş: `NoteSyntax`'ın
aralıklarıyla `[[X|y]]` → `[y](overterm-note:X)`, `#etiket` →
`[#etiket](overterm-tag:etiket)` (kodun içine dokunmadan).
`clickedOnLink`'e bu iki şema için bir dal (`MarkdownPreview.swift:323-336`);
bugün boş yollu bir link hiçbir şey yapmıyor.

### Arama

`CheckoutSearch` git'e bağlı. Notlarda isim araması `FuzzyMatch` ile
indeksten, tam metin araması indeksin tuttuğu metinden; `ContentMatch`
modeli olduğu gibi kullanılır.

### Session

`SessionState`'e yeni bir üst düzey, opsiyonel anahtar: `notes` (Notes açık
mı, hangi vault, vault başına açık notlar ve seçili not). Eski sürümler yok
sayar; MAJOR gerekmez.

### Ajanlar

- **MCP:** tek sunucu var (`Browser/BrowserBridge.swift`); API client'ın
  `api_` grubu gibi bir `notes_` grubu: `BrowserBridge`'e `resolveNotes`,
  `BrowserMCP.handle`'a önek dalı, `offered` ve `instructions`'a birer satır,
  `notes.agentControl` ayarı, `wanted`'a eklenmesi.
- **Araçlar:** `notes_vaults`, `notes_list`, `notes_search`, `notes_read`,
  `notes_write` (oluştur / değiştir / sona ekle), `notes_backlinks`,
  `notes_daily` (bugünün notuna ekle). Vault dışına çıkan yol reddedilir
  (`APIMCPTests`'teki gibi). Editörde açık ve kaydedilmemiş bir nota yazma
  reddedilir. Okuma bulutta duran notu indirir.
- **Ajana sor:** `presentAskAgent(text:command:folder:targets:)` kaynaktan
  bağımsız (`TerminalWindowController.swift:2365-2389`); tarayıcı ve API
  client da kullanıyor. Notlarda seçim ya da notun tamamı, yoluyla birlikte.
  Editörde ⌘L "satırı seç" (`EditCommands.swift:555`), bu yüzden notlarda
  başka bir kısayol.
- **Codex:** bugün hiçbir MCP aracı Codex'e verilmiyor, yalnızca Claude
  `--mcp-config` alıyor (`Settings/Settings.swift:233-243`). Bkz. açık
  sorular.
- **Risk (koddan çıkarım):** uygulama açılırken yaratılan panelere MCP
  yapılandırması verilmiyor olabilir; port, paneller kurulduktan sonra
  yayımlanıyor (`BrowserBridge.swift:115-118`). Tarayıcı araçları için de
  geçerli; spike'ta bakılacak.

### Kısayollar

| Kısayol | Komut | Durum |
|---|---|---|
| ⌥⌘N | Notes'u aç / kapat | Boş |
| ⌘O | Hızlı geçiş (Notes açıkken) | Boş görünüyor; Ghostty'nin `Config.zig`'ine bakılacak |
| ⌘N | Yeni not (Notes açıkken) | Ghostty'nin `new_window`'u; uygulama işlemiyor, şu an bir şey yapmıyor |
| ⇧⌘L | Notu ajana sor | Listede yok; doğrulanacak |
| — | Günlük not | Palet ve menü; ⌥⌘D dolu |

Notes'a ait komutlar Notes görünmüyorken `validateMenuItem`'da kapalı.

## 3. Adımlar

`CLAUDE.md`: uygulamanın içinde bir iç adım PATCH, kullanıcıya görünen yeni
bir özellik MINOR. Her adım derlenir, `make test` ve `make e2e` yeşil. API
client tek commit'te inmişti (`fe846e0`, 65 dosya); bu iş daha büyük ve iCloud
riski taşıyor, bu yüzden bir dalda adım adım öneriyorum.

| # | Commit | Ne | Sürüm | Testler |
|---|---|---|---|---|
| 0 | — | Spike: iCloud davranışı (Bölüm 4) | — | Scratchpad, commit yok |
| 1 | `window: overlays take turns` | `WorkspaceOverlay`; Settings aynen | PATCH | `settings` E2E değişmeden yeşil |
| 2 | `notes: note syntax` | `NoteSyntax`, `NoteLinks` | PATCH | Birim |
| 3 | `notes: vault files` | `CloudFiles` (gerçek + sahte), `NoteVaults`, `VaultConfig`, `AppEnvironment` yeri | PATCH | Birim, geçici klasörlerde |
| 4 | `notes: the index` | `NoteIndex`, artımlı güncelleme, yeniden adlandırma planı | PATCH | Birim |
| 5 | `editor: a host other than the window` | Bölüm 2'deki editör seam'leri | PATCH | `editorZed` E2E değişmeden yeşil |
| 6 | `notes: a workspace for notes` | Overlay, vault değiştirici, ağaç, editör ve yan önizleme, canlı yeniden yükleme, bulut durumu, session, menü ve palet, Settings bölümü | MINOR | `notes` E2E |
| 7 | `notes: links` | Wikilink tıklama ve tamamlama, hızlı geçiş, backlink'ler, yeniden adlandırınca linkleri güncelleme | MINOR | Birim ve `notes` E2E |
| 8 | `notes: search, tags, daily notes, attachments` | Tam metin arama, etiket listesi, günlük not, resim yapıştırma | MINOR | Birim ve `notes` E2E |
| 9 | `notes: conflicts` | Çakışma ekranı (benimki / diğeri / yan yana) | PATCH | Sahte `CloudFiles` ile birim ve E2E |
| 10 | `notes: agents` | `notes_` MCP araçları, ajana sorma | MINOR | `NotesMCPTests`, gerçek HTTP ile E2E (`browser` senaryosu gibi) |

Her kullanıcıya görünen adımda: `docs/architecture.md`'ye "Notes" bölümü
(API client'ınki gibi), `CLAUDE.md`'nin Layout tablosuna bir satır ve
gerekirse bir kural, `docs/testing.md`'nin senaryo listesi, README.

`notes` E2E senaryosu izole vault'ta (`supportDirectory/Notes`) çalışır;
bulut durumları (bulutta, indiriliyor, çakışma) sahte `CloudFiles` ile.
Gerçek iCloud'a hiçbir test dokunmaz.

## 4. Spike

Scratchpad'de küçük Swift programlarıyla; commit edilmez. iCloud Drive'da
`Overterm Spike` adlı bir test klasörü gerekiyor, sonunda silinir.

1. **Dataless okuma.** Test dosyalarını yaz, `evictUbiquitousItem` ile
   buluttan indirilmemiş hale getir, koordineli oku: indiriyor mu, ne kadar
   bekletiyor, ana thread'den çağrılınca ne oluyor?
2. **Değişiklik olayları.** Başka bir cihazdan (iPhone, Dosyalar) bir
   dosyayı düzenle: Mac'te FSEvents ne zaman ve hangi olayla geliyor;
   `NSFilePresenter` ek bir şey söylüyor mu?
3. **Çakışma.** Mac çevrimdışıyken ve iPhone'da aynı dosyayı düzenle, Mac'i
   bağla: `NSFileVersion` çakışması mı oluşuyor, "Not 2.md" gibi bir kopya
   mı?
4. **Atomik yazma.** `Data.write(.atomic)` koordineli yazmanın içinde iCloud'la
   sorunsuz mu (dosya kimliği değişiyor)?
5. **Açılışta MCP.** Açılışta yaratılan bir panelde `OVERTERM_MCP_CONFIG`
   var mı?

1, 4 ve 5'i tek başıma yapabilirim. 2 ve 3 için iPhone'unda birkaç adım
gerekiyor.

### Sonuçlar (2026-10-26, macOS 26.7.1)

Entitlement'sız, ad-hoc derlenmiş bir probe ile `Overterm Spike` klasöründe.

**1. Dataless okuma.**

- `evictUbiquitousItem` entitlement'sız çalışıyor. Dosya `dataless` bayrağı
  alıyor (`ls -O`: `compressed,dataless`), `fileAllocatedSize` 0 oluyor;
  boyut, inode ve mtime aynı kalıyor.
- Okumak, koordinasyonlu da koordinasyonsuz da (`Data(contentsOf:)`,
  `.withoutChanges` ile de), dosyayı indiriyor ve bitene kadar çağıranı
  bekletiyor. Bekleme dosya başına yaklaşık 1 s ve boyuttan bağımsız
  (73 B da 266 KB de ~1.0 s). Ana thread'den çağrılınca ana thread o kadar
  duruyor.
- Ardışık okuma dosya başına 1 s (10 dosya 10 s). 20 paralel okuma 1.6 s'de
  bitti. 40 dosya için tek seferde `startDownloadingUbiquitousItem` çağrısı
  2.0 s'de hepsini indirdi.
- Sonuç: indeks ve not açma hiçbir zaman ana thread'de okumaz. İndeks önce
  bulutta duranların hepsi için indirmeyi başlatır, inmiş olanları okur,
  kalanları indikçe okur.

**4. Atomik yazma.**

- `Data.write(.atomic)` koordinasyonlu da koordinasyonsuz da sorunsuz:
  inode değişiyor; dosya yükleniyor; çakışma ya da ek `NSFileVersion`
  oluşmuyor.
- Dataless bir dosyanın üstüne `.forReplacing` ile koordinasyonlu yazma onu
  önce indirmiyor (7 ms).
- Atomik yazma dosyanın yanında geçici bir `<ad>.md.sb-<hash>-<rastgele>`
  yaratıp yeniden adlandırıyor. İzleyici ve ağaç bu adları yok saymalı.

**İzleyici (FSEvents ve `NSFilePresenter`).**

- Eviction ve indirme FSEvents'te `modified` (ve `xattr`, `inodeMeta`,
  `owner`) olarak geliyor. Yükleme bitince `xattr` olayı geliyor. Her olayda
  yeniden okuyan bir indeks, sistemin buluta geri gönderdiği notları tekrar
  indirir.
- Sonuç: bir dosya ancak mtime'ı ya da boyutu indekstekinden farklıysa
  değişmiş sayılır (`stat` dosyayı indirmez). Bulut durumu ayrıca okunur.
- `NSFilePresenter` aynı değişiklikleri ~1 s sonra, daha az ayrıntıyla
  söylüyor (yalnızca "subitem changed"). FSEvents yeterli.

**5. Açılışta MCP.** Koddan kesin: `BrowserBridge.start()` portu
`listener`'ın `ready` durumunda, `DispatchQueue.main.async` ile yayımlıyor.
`applicationDidFinishLaunching` aynı turda `restore` ile panelleri kuruyor ve
`TerminalView.init` `configPath(forPane:)`'i o sırada soruyor. Port henüz
`nil` olduğu için açılışta kurulan paneller `OVERTERM_MCP_CONFIG` almıyor,
restore edilen Claude da `--mcp-config` almıyor. Tarayıcı ve API araçlarını
bugün de etkileyen bir hata; ayrı bir commit'te düzeltilir, bir check ile.

**Codex (belgelerden, Codex bu makinede kurulu değil).**

- URL'li (streamable HTTP) MCP sunucusu için feature flag gerekmiyor.
- Sunucu çalıştırma başına `-c` ile verilebiliyor (dotted key'ler belgede
  var): `-c 'mcp_servers.overterm.url="…"'`.
- Token ortamdan okunabiliyor: `bearer_token_env_var`.
- Sunucunun `instructions`'ını okuyor. Belge ilk 512 karakterin kendi
  başına anlaşılır olmasını öneriyor.
- Belgelenmemiş olanlar: yeni bir sunucu tablosunun yalnızca `-c` ile
  kurulup kurulamadığı ve MCP araç çağrılarında varsayılan onay davranışı.
  Codex kurulu bir makinede denenecek.

**Düzeltme (analysis.md).** iOS'un Dosyalar uygulaması `.md`'yi Quick Look ile
gösteriyor ama düzenleyemiyor. iPhone'da düzenlemek için dosyayı yerinde
açan bir metin editörü gerekiyor (iA Writer, Runestone, Textastic gibi).

## 6. Durum (2026-10-27)

Adımların hepsi `notes` dalında; her biri kendi commit'inde, testleriyle.

| # | Commit | Sürüm |
|---|---|---|
| — | `build: GhosttyKit builds with Xcode 26` (bu Mac'te derlemek için) | 1.2.1 |
| — | `editor: the Vim engine builds with Swift 6.3` (aynı sebep) | 1.2.2 |
| 1 | `window: overlays take turns` | 1.2.3 |
| 2 | `notes: note syntax` | 1.2.4 |
| 3 | `notes: vault files` | 1.2.5 |
| 4 | `notes: the index` | 1.2.6 |
| — | `agents: a pane made at launch gets the MCP config` (spike'ın 5. sorusu) | 1.2.7 |
| 5 | `editor: a host other than the window` | 1.2.8 |
| 6 | `notes: a workspace for notes` | 1.3.0 |
| 7 | `notes: links` | 1.4.0 |
| 8 | `notes: search, tags, daily notes, attachments` | 1.5.0 |
| 9 | `notes: conflicts` | 1.6.0 |
| 10 | `notes: agents` | 1.7.0 |

Plandan sapmalar:

- **⇧⌘L yerine ⌥⌘L.** ⇧⌘L editörde "Select All Matches"; ⌥⌘L Ghostty'de de
  boş.
- **9. adım MINOR.** Kullanıcının gördüğü bir özellik (CLAUDE.md, Versioning).
- **Settings bölümü yok.** Uygulama düzeyinde tek ayar `agents.notesControl`
  (Settings ▸ Agents); vault'un ayarları `.overterm/notes.json`'da, elle.
- **`[[` tamamlama 7. adımda.** Editör kancası (`completionSource`) onu
  kullanan adımla geldi.
- **Önizleme tek satır sonunu satır sonu sayar,** Obsidian'ın varsayılanı gibi.

Açık kalanlar:

- **Spike 2 ve 3 (iPhone).** Başka bir cihazdan düzenleme ve çakışma gerçek
  iCloud'la denenmedi; testler `SimulatedCloudFiles` ile. Çakışmanın
  `NSFileVersion` biçimi ele alınıyor, "Not 2.md" kopyası alınmıyor.
- **Codex.** `-c mcp_servers…` override'ları belgelere göre; bir Codex
  ikilisiyle denenmedi (bu Mac'te yok).
- **2. aşama** (analysis.md, 4): live preview, gömülü notlar, callout ve
  vurgu çizimi, özellikler arayüzü, başlık ağacı, şablonlar, graf.

## 5. Kararlar (2026-10-26)

1. **Codex de MCP alır,** MVP'de: üç araç grubu birden (tarayıcı, API,
   notlar). Codex'in HTTP MCP desteği spike'ta doğrulanır.
2. **Kısayollar:** ⌥⌘N, ⌘O, ⌘N, ⇧⌘L.
3. **Commit:** `notes` dalında adım adım, sonunda PR.
4. **Spike onaylı:** iCloud Drive'da `Overterm Spike` klasörü, sonunda
   silinir; iPhone'la iki test.
