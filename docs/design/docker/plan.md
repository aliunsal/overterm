# Docker — implementasyon planı

Kararlar `analysis.md`'nin 12. bölümünde. Kısaca:
- iki katman: sayfa (⌥⌘P) ve rail paneli,
- Engine API, arka planda CLI ve terminal,
- 1. aşamada imajlar, volume'lar ve ağlar da var,
- ajanlar için bütün araçlar,
- Docker Desktop, OrbStack ve Colima.

Satır numaraları 2026-10-27'deki `main`'e göre (`3a5aee1`).

## 1. Parçalar

Yeni klasör `Sources/Overterm/Docker/`. Saf olanlar birim testli; socket'e ya
da sürece dokunanlar bir protokolün arkasında, testlerde sahte bir motorla.

### Motorla konuşma

| Parça | Ne yapar | Saf mı |
|---|---|---|
| `DockerEndpoint` | Socket'i bulur: `DOCKER_HOST`, `DOCKER_CONTEXT`, `config.json`'un `currentContext`'i, context kaydı (`meta/<sha256>/meta.json`), varsayılan. Ortamı tanır (Docker Desktop, OrbStack, Colima; socket yolundan ve `/info`'dan) | Evet (dosyalar okunduktan sonra) |
| `DockerEngine` | Unix socket'te HTTP/1.1 (NIOPosix ve NIOHTTP1): istek ve yanıt; chunked akışlar (olaylar, loglar, istatistikler, pull'un ilerlemesi); `/_ping` ile sürüm; kopunca ölçülü aralıklarla yeniden bağlanma | Hayır (sahte motorla test) |
| `DockerAPI` | Uç noktalar ve Codable modeller: konteynerler, imajlar, volume'lar, ağlar, `system/df`, `archive`, prune'lar | Modeller saf |
| `DockerCLI` | `docker` ikilisini bulur (GUI'nin dar PATH'i: `/usr/local/bin`, `/opt/homebrew/bin`, `~/.docker/bin`, `~/.orbstack/bin`); JSON veren eklenti komutlarını bir GCD iş parçacığında çalıştırır | Hayır |
| `DockerRuntime` | Ortamın durumu ve başlat/durdur/yeniden başlat: `docker desktop …`, OrbStack'in `orb start/stop`'u, `colima start/stop` | Hayır |

### Saf yardımcılar

Hepsi birim testli:

| Parça | Ne yapar |
|---|---|
| `DockerLogFrames` | Engine'in 8 byte'lık çoklama çerçevelerini (stdout/stderr) ayırır |
| `DockerLogLine` | Zaman damgası, seviye (JSON loglar ve `level=`/`[ERROR]` biçimleri), ANSI renkleri, compose servis adı |
| `DockerStats` | CPU% iki örnek arası farktan, bellek (önbellek hariç), ağ ve disk toplamları |
| `DockerTar` | Tek dosyalık tar okuma ve yazma, bir klasörün listesi (`archive` uç noktası için) |
| `DockerPorts` | Yayımlanan portlar, IPv4/IPv6 tekrarları birleşik; URL'leri |
| `DockerSecrets` | Env değerlerinde `PASSWORD`, `SECRET`, `TOKEN`, `KEY` içerenleri maskeleme |
| `DockerFilter` | Süzme sözdizimi: metin, `status:`, `project:`, `image:`, `port:` |
| `ComposeProjects` | Compose etiketlerinden proje ve servis ağacı; bir checkout'a (ya da worktree'ye) düşen projeler |
| `DockerRunCommand` | Bir konteynerin ayarından `docker run …` komutu ("Copy as Command") |
| `DockerDatabaseGuess` | İmajdan ve env'den (`POSTGRES_*`, `MYSQL_*`…) bir Database bağlantısı taslağı |
| `DockerPrunePlan` | Prune'un sileceklerinin listesi ve toplam boyutu; kullanımda olanlar hariç |
| `PortConflicts` | Aynı host portunu isteyen konteyner ya da süreç ve sahibi (worktree, tab) |

### Model

| Parça | Ne yapar |
|---|---|
| `DockerModel` | Uygulama için tek (`DatabaseModel` gibi). Bağlantı durumu, olay akışı, konteynerler ve projeler. İmajlar, volume'lar ve ağlar istendiğinde okunur. Görünmüyorken yalnızca olaylar ve liste akar |
| `ContainerSession` | Görünen bir konteynerin logları (son N satır, takip), istatistikleri (yalnızca görünürken), dosyaları |

### Arayüz

| Parça | Ne yapar |
|---|---|
| `DockerPageViewController` | Gövdeyi kaplayan sayfa. Solda bölümler (Konteynerler, İmajlar, Volume'lar, Ağlar; 3. aşamada Build'ler, Modeller), ortada liste (NSTableView), sağda ayrıntı, altta motor çubuğu |
| `DockerPanelView` | Rail paneli: seçili tab'ın checkout'unun stack'i, altında diğerleri; seçilen konteynerin ayrıntısı sağ slotta |
| `ContainerDetailView` | Logs, Inspect, Files, Stats, Mounts sekmeleri; sayfada da sağ slotta da aynı görünüm |
| `DockerLogView` | Loglar: takip, arama, seviye renkleri, JSON açma, servis renkleri; NSTextView, son N satır |
| `DockerKeys` | Liste odaktayken tek harf eylemler, `?` kopya kağıdı. Tablo saf |
| `DockerSwitcher` | ⇧⌥⌘P: konteyner, servis, imaj, volume adıyla geçiş; ↩ ⌘↩ ⌥↩ ⌘O |
| `ImageListView`, `VolumeListView`, `NetworkListView` | Liste ve ayrıntı; imajın katmanları, volume'un kullanıcıları, ağın konteynerleri |
| `DockerRunSheet` | 2. aşama: "Run" penceresi |
| `DockerMCP` | `docker_` araçları; yazmalar pencerede onaylı (`DatabaseMCP.allow` gibi) |
| `TerminalWindowController+Docker` | Sayfanın ve panelin pencereye bağlanması, menüler, palet, kısayollar, tab'lar |

## 2. Mevcut koda dokunulacak yerler

### Sayfalar sırayla

Upstream'de Settings hâlâ tek bayrakla tek sayfa: `TabStore`'un
`settingsOpen`/`settingsShowing`'i, ⌘W, strip'te seçili görünme ve tab
değişince gizleme. Docker sayfası ikinci sayfa olacağı için önce bunun
"sayfalar sırayla" yapısına (`WorkspaceOverlay`) geçmesi gerekiyor.
Settings'in davranışı değişmez; `settings` E2E senaryosu değişmeden yeşil
kalır.

### Rail ve sağ slot

- `SidebarPanel` (`Sidebar/SidebarView.swift:66`) `docker`; `isEnabled`
  ayara bağlı.
- `RightPaneView`'ın modlarına (`Diff/RightPaneView.swift:7`) `container`;
  Storage'ın `.object`'i gibi, yalnızca görünürken okur.

### Portlar

- `ListeningPort` (`Info/ListeningPorts.swift:4`) bugün pid ve süreç adı
  taşıyor. Ona bir kaynak eklenir: süreç ya da konteyner.
- Tab'ın portlarını yazan döngü (`Window/TerminalWindowController.swift:1491`)
  lsof'unkine, tab'ın checkout'una düşen compose projelerinin portlarını
  ekler. Kaynak `DockerModel`, yeni bir sorgu yok.
- Panel başlığındaki gösterge konteyner portunu bir ikonla ayırır. "Kill"
  yerine "Stop container" sunar.

### Tab'lar ve terminal

- **Komutlar:** `newTab(in:running:)` (`:1048`) compose, `exec`, `logs -f`,
  build ve pull/push için.
- **`exec` tab'ı:** türü `container` (`TabKind`, `Tabs/TabKind.swift:13`).
  Tab, konteynerin adını taşır; konteyner durunca bunu söyler.
- **Dikkat:** Çıkan ya da sağlıksız konteyner, `TabActivity` ve
  `AttentionNotifier` üzerinden onu başlatan tab'ı işaretler. "Başlatan
  tab": compose projesinin `working_dir`'i tab'ın checkout'u.

### Editör ve Database

- **Konteyner dosyası:** Overterm'in önbellek klasöründe geçici bir kopya
  olarak açılır. Editör kaydedince (`onSaved`) `archive` PUT ile konteynere
  geri yazılır; konteyner o arada değiştiyse sorulur.
- **Database'e geçiş:** Bağlantının taslağı `DatabaseModel`'e verilir,
  bağlantı formu dolu açılır, şifre keychain'e gider.

### Ayarlar, kısayollar, MCP

- **Settings ▸ Docker bölümü (`SettingsSection.docker`):**
  - `docker.enabled`
  - `docker.endpoint` (boş: otomatik)
  - `docker.showAllContainers` (panelde diğerleri)
  - `docker.notifyOnExit`
  - `docker.agentAccess` (okuma)
  - `docker.agentWrites` (onaylı eylemler)
- **`KeyCommands` ve `MainMenu` (View ▸ Docker):**
  - `docker.page` (⌥⌘P)
  - `docker.switch` (⇧⌥⌘P)
  - `docker.composeUp`, `docker.composeDown`, `docker.composeRestart` (kısayolsuz; palet ve menü)
- **Palet:** Konteynerler adlarıyla ve eylemleriyle.
- **MCP:** `BrowserMCP.handle`'a `docker_` dalı (`Browser/BrowserMCP.swift`).
  `BrowserBridge`'in `wanted`'ına `docker.agentAccess`.

### Paket ve ortam

- `Package.swift`'e `NIOHTTP1` (swift-nio'nun ürünü; yeni paket yok).
- `AppEnvironment`: E2E ve testler için `OVERTERM_DOCKER_HOST`.

## 3. Adımlar

| # | Commit | Ne | Sürüm | Testler |
|---|---|---|---|---|
| 0 | — | Bu Mac'te derleme ortamı: mise, Zig 0.15.2; Xcode 26 için GhosttyKit düzeltmesi (reflog'daki `23579ff`'in bugünkü script'e uyarlanmışı). Spike (Bölüm 4) | — | `make app` |
| 1 | `window: pages take turns` | `WorkspaceOverlay`; Settings aynen | PATCH | `settings` E2E değişmeden |
| 2 | `docker: the engine` | `DockerEndpoint`, `DockerEngine`, `DockerAPI` modelleri, saf yardımcıların motora ait olanları (çerçeveler, tar, istatistik, portlar) | PATCH | Birim; sahte motorla |
| 3 | `docker: the model` | `DockerModel`, olaylar, `ComposeProjects`, `DockerRuntime`, `DockerCLI` | PATCH | Birim; sahte motorla |
| 4 | `docker: containers and compose` | Birkaç commit (aşağıda) | MINOR | `docker` E2E (sahte motor) |
| 4a | `docker: the page` | Sayfa (⌥⌘P), konteynerler ve projeler, eylemler; ayrıntı: Overview, Logs (takip), Inspect (sırlar gizli), Stats; `DockerKey`, `DockerFilter`, `DockerCommands`; motor kartı; Settings ▸ Docker | MINOR | Birim ve `docker` E2E |
| 4c | `docker: the rail panel` | Checkout'un stack'i rail'de, ayrıntısı sağ slotta | MINOR | `docker` E2E |
| 4d | `docker: the switcher` | ⇧⌥⌘P, palet, `exec` tab'ının türü (`TabKind`) | MINOR | Birim ve E2E |
| 5 | `docker: images, volumes, networks` | Listeler ve ayrıntılar; pull (ilerlemeyle), tag, delete; volume'u gezme; ağlar; önizlemeli prune'lar | MINOR | Birim ve `docker` E2E |
| 6 | `docker: around the terminal` | Portlar panel başlığında ve tarayıcıda; dikkat işaretleri; Database'e geçiş; Files sekmesi (klasör listesi `exec` ister: `archive` bir klasörün bütün ağacını döndürür) ve konteyner dosyasını editörde düzenleme | MINOR | Birim ve E2E |
| 7 | `docker: agents` | `DockerMCP`: okuma ve onaylı eylemler | MINOR | `DockerMCPTests`, gerçek HTTP ile E2E |
| 8 | `docker: management` | 2. aşama: disk ve temizlik görünümü, `daemon.json`, compose'un çözülmüş modeli ve editörde compose, worktree çakışmaları, Run penceresi, Docker Debug karşılığı, `top`/`changes`/`export`, Tab Info, OpenAPI araması | MINOR (birkaç commit) | Her biri kendi testiyle |
| 9 | `docker: …` | 3. aşama: build geçmişi, Scout, Hub, volume dışa/içe aktarma, Model Runner, MCP Toolkit, güncellemeler ve tanılama, Kubernetes durumu, uzak context'ler, Podman ve Rancher | MINOR (eklenti başına bir commit) | Eklentinin JSON örnekleriyle |

Her kullanıcıya görünen adımda:
- `docs/architecture.md`'ye "Docker" bölümü,
- `CLAUDE.md`'nin Layout tablosuna bir satır ve gerekirse bir kural,
- `docs/testing.md`'nin senaryo listesi,
- README.

### Test ortamı

- **Sahte motor:** Testlerde ve `docker` E2E senaryosunda bir unix socket'te
  Engine API'sini taklit eden küçük bir sunucu. Senaryo kullanıcının
  Docker'ına dokunmaz.
- **Gerçek Docker:** `OVERTERM_DOCKER_TESTS=1` ile `DockerLiveTests` ve
  `dockerLive` senaryosu. Makinede zaten olan bir imajdan (`debian:bookworm-slim`)
  etiketli konteynerler ve iki servisli bir compose projesi kaldırır;
  yalnızca kendi etiketlilerini siler.
- **Ortamlar:** OrbStack ve Colima bu Mac'te yok. Socket yolları ve
  `DockerRuntime`'ın komutları sahte motorla ve sahte `PATH`'le test edilir.

## 4. Spike

Scratchpad'de küçük programlarla; commit edilmez. Kullanıcının Docker'ında
yalnızca `overterm.spike=1` etiketli, makinede zaten olan imajlardan
konteynerler; sonunda silinir.

1. **NIO ile socket:** Uygulamanın içinden `containers/json`, chunked
   `events` ve çerçeveli `logs?follow=1`. Akış kesilince ne oluyor
   (Docker Desktop yeniden başlarken)?
2. **Compose etiketleri:** İki servisli bir compose projesi (`debian:bookworm-slim`,
   `sleep`). Etiketler, `working_dir`, `oneoff`; bir worktree'den başlatınca
   proje adı.
3. **Dosya yazma:** `archive` PUT ile bir dosyayı geri yazmak; konteyner
   dururken de.
4. **Port çakışması:** İkinci projede aynı host portu. Engine'in hatası ve
   olayları; portun sahibini bulmak.
5. **`exec` tab'ı:** `docker exec -it` bir Ghostty tab'ında. Çıkınca ne oluyor,
   konteyner durunca ne oluyor?
6. **Eklentiler:** `docker desktop status --format json`, `docker model list --json`,
   `docker buildx history ls --format json` gerçek çıktıları (yalnızca okuma).

### Sonuçlar (2026-10-27, Docker Desktop 4.95)

İki compose projesi (`overterm-spike-stack`, `-2`), `debian:bookworm-slim`'den,
`overterm.spike=1` etiketli; sonunda indirildi, geride bir şey kalmadı.

**Compose etiketleri.**
- Hepsi geliyor: `project`, `service`, `container-number`, `oneoff`,
  `config_files`, `config-hash`, `image`, `version`.
- `depends_on` `db:service_started:false` biçiminde.
- `working_dir` **çözülmüş yolu** taşıyor (`/private/tmp/…`): checkout'la
  realpath'leri karşılaştırılmalı (`FileTreeModel.realPath` gibi).

**Port çakışması.**
- İkinci projenin `web`'i başlamadı: `created` durumunda, `ExitCode` 128.
- `State.Error`'da tam hata yazıyor: "Bind for 0.0.0.0:58080 failed: port is
  already allocated".
- Port ve hata konteynerin üstünden okunabiliyor; `docker compose up`'ın
  çıkışını ayrıştırmak gerekmiyor.

**Loglar.**
- Çerçeveler doğrulandı; stdout ve stderr ayrı, zaman damgalı.
- JSON satırlar olduğu gibi geliyor.
- Takip edilen akış konteyner durunca temiz kapanıyor.

**Dosya yazma (`archive` PUT).**
- macOS'un `tar`'ıyla 500 dönüyor: dosyanın `com.apple.provenance`
  genişletilmiş özniteliği PAX başlığına giriyor. Dosya yazılıyor ama motor
  özniteliği koyamıyor.
- Öznitelik içermeyen düz `ustar` ile 200; durmuş konteynerde de.
- Sonuç: `DockerTar` kendi düz `ustar`'ını yazar, sistemin `tar`'ını
  kullanmaz.

**Olaylar.**
- Bir dakikada 211 olay geldi; 189'u `exec_create`/`exec_start`/`exec_die`.
  Bunlar sağlık kontrollerinden (2 s aralık, iki servis).
- Model olayları bir izin listesiyle süzmeli: create, start, die, stop, kill,
  pause, unpause, restart, destroy, rename, health_status, oom.
- `health_status: healthy` compose etiketleriyle geliyor.
- Kendi `archive` işlerimiz de olay üretiyor (`archive-path`,
  `extract-to-dir`).

**Eklentiler.**
- `docker desktop status --format json` temiz JSON (`Status`, `PauseType`).
- `docker model list --json`, Model Runner kapalıyken JSON yerine bir uyarı
  metni basıyor ("not running"). Eklentinin durumunu ayrıca tanımak
  gerekiyor.

**Henüz denenmeyenler.** NIO ile socket ve `exec` tab'ı uygulamanın içinde
denenecek: 2. adımın testleri (sahte motor ve `OVERTERM_DOCKER_TESTS`) ve 4.
adımın senaryosu.

## 5. Kararlar (2026-10-27)

1. **Dal ve PR:** `docker` dalında adım adım commit'ler. Önce her şey yerelde
   biter, PR en sonda açılır.
2. **Derleme düzeltmesi:** Xcode 26 için GhosttyKit düzeltmesi `docker` dalının
   ilk commit'i.
3. **Spike onaylı:** `overterm.spike=1` etiketli geçici konteynerler ve bir
   compose projesi, makinede olan imajlardan; sonunda silinir. mise ve Zig
   yeniden kurulur.
4. **Ajanların yazmaları:** `docker.agentWrites` varsayılan açık; her eylem
   yine pencerede sorulur.
