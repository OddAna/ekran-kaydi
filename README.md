# Ekran Kaydı

macOS menü çubuğunda duran sade bir ekran kayıt uygulaması: ekranı **bilgisayarın sesiyle (sistem sesi)**
birlikte, istenirse mikrofonla da kaydeder. Dock simgesi ve penceresi yoktur; her şey menü çubuğundaki
daire simgesinin menüsündedir. Arayüz Türkçedir.

Kurulum ve ilk kullanım adım adım: [KURULUM.md](KURULUM.md).

## Özellikler

- Menü çubuğundan **Kaydı Başlat / Kaydı Durdur**; kayıt sürerken simge kırmızı, yanında geçen süre.
- **Ekran seçimi:** liste her menü açılışında o Mac'e bağlı ekranlardan (`NSScreen.screens`) kurulur.
  Kodda cihaza sabit ekran adı ya da kimliği yoktur; aynı adlı iki ekran "(1)", "(2)" diye ayrılır.
  Kayıtlı seçim artık bağlı değilse ana ekrana düşülür.
- **Bilgisayarın sesi** (varsayılan açık) ve **Mikrofon** (varsayılan kapalı, sistemin varsayılan girişi).
  İkisi birlikte kaydedilirse durdurunca tek ses izine karıştırılır (görüntü yeniden sıkıştırılmaz),
  böylece her oynatıcıda ve yüklenen her sitede ikisi birlikte duyulur.
- **Kayıt yeri:** Filmler › Ekran Kayıtları ya da Masaüstü. Dosya adı `Ekran Kaydı 2026-11-10 18.40.12.mov`;
  var olan dosyanın üzerine yazılmaz. Kayıt bitince Finder dosyayı seçili gösterir.
- Kayıt sırasında ekran çıkarılır ya da macOS paylaşımı durdurursa o ana kadarki kayıt saklanır.
- Uygulamadan kayıt sürerken çıkılırsa önce kayıt kapatılıp kaydedilir.
- Hesap, sunucu, anahtar, ağ bağlantısı yok; hiçbir veri dışarı gönderilmez.

## Desteklenen macOS

| macOS | Durum |
| --- | --- |
| 13 Ventura ve sonrası | Tam: ekran + bilgisayarın sesi + isteğe bağlı mikrofon (ScreenCaptureKit) |
| 12 Monterey | Açılır; ekran + isteğe bağlı mikrofon. Bilgisayarın sesi **yok** (macOS 12 sistem sesini uygulamalara vermez; macOS'un kendi `screencapture -v` aracı kullanılır) |
| 11 Big Sur ve öncesi | Desteklenmez (Xcode 27 SDK'sı en düşük macOS 12'ye derleyebiliyor) |

- **En düşük macOS: 12.0.** Bilgisayarın sesiyle kayıt için **13.0**.
- Universal derlenir: Apple Silicon (arm64) ve Intel (x86_64).
- macOS 12'de sistem sesi ancak BlackHole gibi ayrı bir sanal ses sürücüsüyle alınabilir; bu uygulama
  sürücü kurmaz.

## Derleme

Gerekli: Xcode (27 ile denendi). Ek paket yok.

```sh
sh scripts/build-app.sh 1.0.0 1
# dist/Ekran Kaydı.app ve dist/Ekran-Kaydi-1.0.0.zip
```

Betik universal `swift build -c release --arch arm64 --arch x86_64` yapar, `.app` paketini kurar,
ad-hoc imzalar (`codesign --sign -`) ve `ditto` ile zip'ler. Geliştirici sertifikası ve notarization yoktur;
bu yüzden ilk açılışta **Gizlilik ve Güvenlik › Yine de Aç** gerekir (KURULUM.md › 3).

## Test

```sh
swift test --parallel --num-workers 4
# Intel yolu (Apple Silicon'da Rosetta ile):
swift build --build-tests --arch x86_64 && arch -x86_64 xcrun xctest .build/out/Products/Debug/EkranKaydiCoreTests.xctest
```

Testler izin istemeyen kısmı kapsar: ayarlar, dosya adı, kayıt klasörü, ekran listesinin bu Mac'ten
kurulması ve aynı adlı ekranlar, kaynakta sabit ekran adı/kullanıcı yolu olmaması, motor seçimi
(macOS 12 / 13+), `screencapture` argümanları, yazıcı (yapay görüntü + iki ses izi, son karenin bitişe
uzatılması, mikrofon saatinin kaydırılması) ve karıştırıcı (tek ses izi, mikrofonun gerçekten karışması,
boş sistem sesi izi, görüntünün yeniden sıkıştırılmaması).

Gerçek ekran/sistem sesi yakalaması izin penceresi açtığı için otomatik testte yoktur; ilk gerçek deneme
kurulduğu Mac'te yapılır.

## Yapı

```
Package.swift
Resources/Info.plist                 LSUIElement, mikrofon izin metni, en düşük macOS 12.0
Sources/EkranKaydi/                  menü çubuğu uygulaması (AppKit)
  main.swift, AppDelegate.swift      menü, izinler, kayıt akışı, uyarılar
Sources/EkranKaydiCore/              kayıt motoru (test edilir)
  RecordingSettings.swift            ayarlar, kayıt yeri, dosya adı, süre biçimi
  Displays.swift                     ekran listesi (o Mac'ten), kayıt boyutu, bit hızı
  Recorder.swift                     istek, hatalar, macOS sürümüne göre motor seçimi
  ScreenCaptureKitRecorder.swift     macOS 13+: SCStream + mikrofon (AVCaptureSession)
  MovieWriter.swift                  H.264 + AAC .mov yazıcı (AVAssetWriter)
  AudioMixer.swift                   ses izlerini tek ize karıştırma (görüntü passthrough)
  SystemScreencaptureRecorder.swift  macOS 12: /usr/sbin/screencapture -v
Tests/EkranKaydiCoreTests/
scripts/build-app.sh                 universal derleme, .app, ad-hoc imza, zip
```

## Bilinen sınırlar

- Mikrofon olarak sistemin varsayılan girişi kullanılır (Sistem Ayarları › Ses › Giriş'ten seçilir).
- Bir kayıtta tek ekran kaydedilir.
- Uygulama imzasızdır (ad-hoc); her yeni sürümde macOS izinleri yeniden isteyebilir.
- macOS 12 yolu (`screencapture -v`) yalnız derleme ve argüman testleriyle doğrulandı, macOS 12 makinede denenmedi.
