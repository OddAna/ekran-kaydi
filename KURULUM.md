# Ekran Kaydı: kurulum

Menü çubuğunda duran, ekranı bilgisayarın sesiyle birlikte kaydeden küçük bir uygulama.
Aşağıdaki adımları sırayla izlemen yeterli; her adım bir kez yapılır.

**Gereken:** macOS 13 Ventura ya da daha yenisi (bilgisayarın sesi için).
macOS 12 Monterey'de de açılır ama orada yalnız görüntü ve mikrofon kaydedilir, bilgisayarın sesi kaydedilemez.
Daha eski macOS'ta (11 Big Sur ve öncesi) açılmaz.

Mac'in sürümüne bakmak için: sol üstteki elma simgesi › **Bu Mac Hakkında**. Açılan pencerede "macOS Ventura 13…",
"macOS Sonoma 14…" gibi yazar.

## 1. İndir

1. Sürüm sayfasını aç: <https://github.com/OddAna/ekran-kaydi/releases/latest>
2. Sayfadaki **Ekran-Kaydi-<sürüm>.zip** dosyasına tıkla, inecek (ör. `Ekran-Kaydi-1.1.0.zip`).

Sayfa herkese açıktır, GitHub hesabı gerekmez.

Eski bir sürüm zaten kuruluysa aşağıdaki **Güncelleme** bölümündeki tek satır yeter.

## 2. Uygulamalar klasörüne taşı

1. Finder'da **İndirilenler** klasörünü aç.
2. **Ekran-Kaydi-<sürüm>.zip** dosyasına çift tıkla. Yanında **Ekran Kaydı** uygulaması belirir.
3. **Ekran Kaydı**'nı sürükleyip soldaki **Uygulamalar** klasörüne bırak.

## 3. İlk açılış (bir kez)

Uygulama Apple'a kayıtlı bir geliştirici imzası taşımıyor. Bu yüzden macOS ilk seferde açmaz, bir kez senin onayın gerekir.

1. **Uygulamalar** klasöründe **Ekran Kaydı**'na çift tıkla.
2. "Apple, Ekran Kaydı'nın kötü amaçlı yazılım içermediğini doğrulayamadı" gibi bir uyarı çıkar. **Bitti** (ya da **Tamam**) de.
3. **Sistem Ayarları** › **Gizlilik ve Güvenlik**'i aç, sayfayı en alta kaydır.
4. "Ekran Kaydı engellendi…" satırının yanındaki **Yine de Aç**'a bas. Parolanı (ya da Touch ID'ni) sor, onayla.
5. Çıkan pencerede yine **Yine de Aç**'a bas.

Sürüme göre küçük farklar:

- **macOS 13 ve 14:** Uygulamaya Control tuşuna basılıyken tıklayıp **Aç** demek de olur.
- **macOS 12:** Yol **Sistem Tercihleri** › **Güvenlik ve Gizlilik** › **Genel** sekmesi › **Yine de Aç**.

Uygulama açılınca ekranın üstündeki menü çubuğunda, saatin yanında küçük bir **daire** simgesi belirir.
Dock'ta görünmez; uygulamanın tamamı bu simgenin menüsündedir.

## 4. İzinler

### Ekran kaydı izni (şart)

1. Menü çubuğundaki daireye tıkla, **Kaydı Başlat**'a bas.
2. macOS "Ekran Kaydı bu bilgisayarın ekranını ve sesini kaydetmek istiyor" der. **Sistem Ayarları'nı Aç**'a bas.
3. Açılan listede **Ekran Kaydı**'nın yanındaki anahtarı aç. Parolanı sorarsa gir.
   - macOS 15 ve sonrasında bu bölümün adı **Ekran ve Sistem Sesi Kaydı**dır.
   - macOS 13 ve 14'te adı **Ekran Kaydı**dır.
   - macOS 12'de yol **Sistem Tercihleri** › **Güvenlik ve Gizlilik** › **Gizlilik** › **Ekran Kaydı**; önce alttaki kilide tıklayıp parolanı girmen gerekir.
4. macOS **Çık ve Yeniden Aç** derse bas. Demezse menüden **Çıkış** de, sonra uygulamayı **Uygulamalar**'dan yeniden aç.

### Mikrofon izni (isteğe bağlı)

Yalnız kendi sesini de kaydetmek istersen gerekir.

1. Menüde **Ses** altındaki **Mikrofon**'u işaretle.
2. İlk kayıtta macOS "Ekran Kaydı mikrofona erişmek istiyor" der. **İzin Ver**'e bas.

Yanlışlıkla **İzin Verme**'ye basarsan: **Sistem Ayarları** › **Gizlilik ve Güvenlik** › **Mikrofon** › **Ekran Kaydı** anahtarını aç.

## 5. İlk kayıt

1. Menü çubuğundaki daireye tıkla.
2. **Ekran** altında kaydedilecek ekranı seç. Liste o an bu bilgisayara bağlı ekranlardan oluşur; tek ekran varsa zaten seçilidir.
3. **Ses** altında **Bilgisayarın sesi** işaretli kalsın. Kendi sesin de girsin istersen **Mikrofon**'u da işaretle.
4. **Kayıt yeri** altında **Filmler** ya da **Masaüstü**'nü seç.
5. **Kaydı Başlat**'a bas. Daire dolu (●) olur, yanında geçen süre yazar. Simge menü çubuğundaki öteki
   simgelerle aynı renkte kalır (koyu çubukta beyaz).
6. Kayıt sürerken mikrofonu açıp kapatmak için daireye tıkla, **Mikrofon**'a bas (menü açıkken **M** tuşu da olur).
   Kayıt kesilmez; mikrofon kapalıyken geçen süre kayıtta sessiz kalır. Seçim bir sonraki kayıt için de hatırlanır.
7. Bitirmek için daireye tıklayıp **Kaydı Durdur** de. Kısa bir "Kaydediliyor…" yazısından sonra Finder açılır ve kayıt seçili olarak gösterilir.

## 6. Kayıt nereye düşer

- **Filmler** seçiliyse: **Filmler** › **Ekran Kayıtları** klasörü.
- **Masaüstü** seçiliyse: doğrudan masaüstü. İlk seferde macOS "Masaüstü klasörüne erişmek istiyor" diye sorar; **İzin Ver** de.

Dosya adı kaydın başladığı anı taşır, örneğin `Ekran Kaydı 2026-11-10 18.40.12.mov`.
Menüdeki **Kayıt Klasörünü Aç** klasörü, **Son Kaydı Göster** de son kaydı Finder'da gösterir.
Dosya QuickTime Player'da açılır, olduğu gibi WhatsApp'a, Drive'a ya da YouTube'a yüklenebilir.

## 7. Bilgisayar açılınca kendiliğinden başlasın (isteğe bağlı)

**Sistem Ayarları** › **Genel** › **Giriş Öğeleri** › **Oturum Açıldığında Aç** altındaki **+**'ya bas, **Uygulamalar**'dan **Ekran Kaydı**'nı seç.

## Bir şey ters giderse

- **Kayıtta bilgisayarın sesi yok:** Menüde **Bilgisayarın sesi** işaretli mi bak. Yanında "macOS 13 ve üstü gerekir" yazıyorsa bu Mac'in macOS'u sistem sesine izin vermiyor; macOS'u güncellemek gerekir.
- **"Ekran kaydı izni gerekiyor" uyarısı:** 4. adımı yeniden yap, sonra uygulamadan çıkıp yeniden aç.
- **macOS ara sıra "ekranına erişmeye devam etsin mi" diye soruyor:** Bu macOS 15'in olağan hatırlatmasıdır; **İzin Ver** de.
- **Kayıt sürerken ekranın üst köşesinde mor/renkli bir simge var:** macOS ekranın kaydedildiğini gösteriyor; normaldir.
- **Kayıt sürerken kulaklık ya da AirPods takıldı/çıkarıldı:** Kayıt durmaz. Mikrofon macOS'un o anki
  varsayılan girişine (ör. AirPods'un mikrofonu, çıkarınca Mac'in kendi mikrofonu) kendiliğinden geçer;
  geçiş sırasındaki bir saniyeden kısa an sessiz kalır. Bilgisayarın sesi kulaklıktan da hoparlörden de kaydedilir.
- **Kayıt sırasında ekran kablosu çıkarıldı:** Kayıt o ana kadar kaydedilen kısımla saklanır, uygulama bunu bir uyarıyla bildirir.
- **Yeni sürüm kurdun ve izinler kayboldu:** Eski **Ekran Kaydı**'nı Çöp Sepeti'ne at, yenisini Uygulamalar'a koy, 3. ve 4. adımları bir kez daha yap.

## Güncelleme

**Terminal**'i aç (Uygulamalar › İzlenceler › Terminal), aşağıdaki satırı yapıştır, Enter'a bas. Kayıt sürüyorsa önce
kaydedip kapatır, eski uygulamayı yenisiyle değiştirir ve açar:

```sh
osascript -e 'if application id "app.ekrankaydi.menubar" is running then tell application id "app.ekrankaydi.menubar" to quit'; sleep 3; curl -fsSL -o /tmp/Ekran-Kaydi.zip https://github.com/OddAna/ekran-kaydi/releases/latest/download/Ekran-Kaydi.zip && rm -rf "/Applications/Ekran Kaydı.app" && ditto -x -k /tmp/Ekran-Kaydi.zip /Applications && rm -f /tmp/Ekran-Kaydi.zip && { tccutil reset ScreenCapture app.ekrankaydi.menubar; tccutil reset Microphone app.ekrankaydi.menubar; } >/dev/null 2>&1; open "/Applications/Ekran Kaydı.app"
```

Uygulama imzasız (ad-hoc) olduğu için macOS her yeni sürümü yeni bir uygulama sayar: güncellemeden sonraki ilk
kayıtta ekran kaydı (ve mikrofon açıksa mikrofon) izni bir kez daha istenir; 4. adımdaki gibi izin ver.
