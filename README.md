<img src="SafariExtension/icon.png" alt="Kadraj uygulama simgesi" width="96">

# Kadraj

Safari videosunu, bir görüşme penceresini veya seçtiğiniz ekran alanını diğer uygulamaların üzerinde tutan açık kaynaklı macOS uygulaması. Fare Kadraj’ın üzerine geldiğinde pencere saydamlaşır ve tıklamalar alttaki uygulamaya geçer. Kontrolleri açmak için **⌘** tuşunu basılı tutun.

[**Kadraj’ı indir**](https://github.com/Emirbal23/Kadraj/releases/latest) · [Sorun bildir](https://github.com/Emirbal23/Kadraj/issues/new) · [MIT lisansı](LICENSE)

## Kurulum

1. **macOS 14 veya üzeri** bir Mac’te [son sürümü](https://github.com/Emirbal23/Kadraj/releases/latest) açın. Mac’inize uygun ZIP’i seçmek için ** → Bu Mac Hakkında** bölümündeki çip veya işlemci bilgisine bakın.
2. ZIP’i açın, **Kadraj.app**’i **Uygulamalar** klasörüne taşıyın ve açın. Kadraj menü çubuğunda görünür. Güncelliyorsanız önce açık olan Kadraj’dan çıkın.
3. Hazır paket ad hoc imzalıdır. Apple noter onayı bulunmadığı için macOS ilk açılışta izin isteyebilir. İndirdiğiniz pakete güveniyorsanız ilk açma denemesinden sonra **Sistem Ayarları → Gizlilik ve Güvenlik → Yine de Aç** seçeneğini kullanabilirsiniz. [Apple’ın açılış adımları](https://support.apple.com/tr-tr/102445)

### Safari’yi bağlama

1. Kadraj’daki ilk açılış teklifini veya **Kadraj → Ayarlar → Safari uzantısını etkinleştir…** seçeneğini kullanın.
2. Safari’de **Ayarlar → İleri Düzey → Web geliştiricileri için özellikleri göster** seçeneğini açın. **Ayarlar → Geliştirici → İmzasız uzantılara izin ver** seçeneğini işaretleyin, ardından **Ayarlar → Uzantılar** bölümünde **Kadraj Safari**’yi etkinleştirin. Safari’den tamamen çıktığınızda imzasız uzantı izni sıfırlanır. [Apple’ın Safari uzantısı belgeleri](https://developer.apple.com/documentation/safariservices/running-your-safari-web-extension)
3. Menüden **Safari’ye bağlan…**’ı seçin. Açılan yerel sekme Kadraj ile otomatik eşleşir. Safari yerel erişim sorarsa uzantı düğmesindeki **Yerel bağlantıya izin ver** seçeneğini kullanın.
4. Uzantıya video izlediğiniz site için izin verin, sekmeyi yenileyin ve videoyu oynatın. Menü çubuğunun yanında görünen **Kadraj’da aç** düğmesine basın. Beş saniyelik öneri kapandıysa menüde **Bulunan videoyu Kadraj’da aç** seçeneğine bakın.

## Kontroller

| İşlem | Kullanım |
| --- | --- |
| Pencereyi yönet | Fare üzerindeyken **⌘** basılı tutun. Buradan desteklenen kaynakları duraklatabilir, ileri veya geri sarabilir ve geçen süreyi görebilirsiniz. Taşımak için pencereyi, boyutlandırmak için kenarını sürükleyin. |
| En-boy oranını koru | Kontrol çubuğundaki kilit simgesini kullanın. |
| Gizle / göster | Göz simgesine basın veya **⌃⌥⇧K** kullanın. Video oynatılmaya devam eder. |
| Kapat | **⌃⌥⇧W**. Gizleme ve kapatma kısayolları **Ayarlar → Klavye kısayolları** altında değiştirilebilir. |
| Saydamlığı ayarla | **Kadraj → Ayarlar** altında fare üzerindeyken uygulanacak saydamlığı ve **⌘** ipucunu ayarlayın. |

## Hangi kaynaklar çalışır?

- **Safari ve YouTube.** Desteklenen YouTube videolarında Kadraj asıl sekmedeki video karelerini gösterir. Ses ve oynatma Safari’den gelir. Safari kare erişimine izin verdiğinde sekme değiştirseniz de kaynak aynı kalır.
- **Doğrudan video.** macOS’un açabildiği bir medya bağlantısını Kadraj devralabilir. Safari üzerinden devralınan videoyu kapattığınızda Kadraj son oynatma konumunu aynı Safari oynatıcısına yazmaya çalışır.
- **Pencere veya bölge.** **Videoyu yakala…** ile pencerenin bir bölgesini, **Pencereyi canlı sabitle…** ile görüşme gibi bir uygulama penceresini veya **Görüntüyü sabitle…** ile tek kareyi seçin. macOS ekran kaydı izni isteyebilir.
- **Sınırlar.** DRM korumalı, oturumla kısıtlanmış veya bazı gömülü videolar doğrudan aktarılamayabilir. Bir Safari sekmesinin görünür alanı yakalanıyorsa görüntü o sekmenin ekranda görünmesine bağlıdır.

## Safari izinleri

Uzantı, izin verdiğiniz sayfalarda video öğelerini algılar. Kadraj ile eşleşme ve kare aktarımı bu Mac’teki yerel bağlantı (**127.0.0.1**) üzerinden yapılır. Eşleşme bağlantısı tek kullanımlıktır. Safari çerezleri aktarılmaz. Ekran kaydı izni pencere ve bölge yakalamada, Otomasyon izni ise isteğe bağlı Apple Events algılamasında kullanılır.

## Kaynaktan derleme

macOS 14 veya üzeri ve Xcode ya da güncel Xcode Command Line Tools gerekir. Derleme Mac’in işlemci mimarisini hedefler. Node.js yalnızca JavaScript testleri için gereklidir.

```sh
git clone https://github.com/Emirbal23/Kadraj.git
cd Kadraj
./build.sh
open build/Kadraj.app
```

```sh
node Tests/video.test.cjs
node Tests/safari-bridge.test.cjs
./build/Kadraj.app/Contents/MacOS/Kadraj --check-automation
./build/Kadraj.app/Contents/MacOS/Kadraj --check-window
```

Bir sorun bildirirken macOS ve Safari sürümünü, Kadraj sürümünü ve sorunu yeniden oluşturma adımlarını ekleyin. Eşleşme kodlarını ve özel video bağlantılarını paylaşmayın.

## Lisans

Kadraj [MIT lisansıyla](LICENSE) yayımlanır.
