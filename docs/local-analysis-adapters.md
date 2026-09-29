# Yerel analiz adaptörleri

`local.analysis`, Flutter veya mobil katmandan doğrudan bir kütüphaneye gitmez. İstek mevcut görev
akışında `RuntimeBridge -> capability registry -> safety policy -> native adapter` sınırından geçer ve
yalnız JSON uyumlu yapılandırılmış sonuç döndürür.

Seçilen birincil adaptörler:

- **MarkItDown:** PDF, Office ve metin belgelerini tek, küçük ve bakımı süren bir arayüzden metne
  dönüştürür. Yalnız `extract_document` çağrısında içe aktarılır.
- **DuckDB:** CSV, TSV, JSON, JSONL ve Parquet dosyalarını bellekteki `data` görünümünden sorgular.
  Yalnız `SELECT` ve `WITH` kabul edilir; eklenti yükleme, dosya okuma fonksiyonları, ağ ve yazma
  ifadeleri kapalıdır.
- **SymPy:** Sembolik sadeleştirme ve denklem çözümü için deterministik yerel sonuç verir. Yalnız
  izin listesindeki karakter ve fonksiyonlar işlenir.

Bu bağımlılıklar opsiyoneldir ve masaüstü başlangıcında yüklenmez. Eksik bağımlılık
`DEPENDENCY_MISSING`, zaman aşımı `LOCAL_ANALYSIS_TIMEOUT`, geçersiz veya işlenemeyen girdi
`LOCAL_ANALYSIS_FAILED` olarak döner. Ham istisna, özel dosya içeriği veya mutlak yol loglanmaz.
Dosya sürümü, sorgu ve limit aynı kaldığında en fazla 32 sonuç cihaz belleğinde tutulur. Çalışma alanı
farkı ayrı, süre ve öğe sayısı sınırlı bir dosya anlık görüntüsü kullanır.
