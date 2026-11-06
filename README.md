# WiFi Share

Aplikasi kecil untuk membagikan internet PC sebagai hotspot WiFi, plus QR code
supaya HP bisa langsung konek tanpa mengetik password.

Tidak perlu install apa pun. Cukup Windows 10/11 dengan adapter WiFi.

## Cara pakai

1. Double-click **WifiShare.bat**
2. Isi nama WiFi dan password (min. 8 karakter)
3. Klik **Aktifkan Hotspot**
4. Scan QR di sisi kanan pakai kamera HP

Tombol **Matikan** mematikan hotspot. **Simpan Pengaturan** menerapkan SSID/password
baru; kalau hotspot sedang aktif, hotspot akan dinyalakan ulang otomatis.

## Catatan

- Aplikasi ini memakai fitur **Mobile Hotspot** bawaan Windows (Wi-Fi Direct),
  bukan `netsh wlan set hostednetwork` yang sudah usang.
- Internet sumber bisa dari Ethernet maupun WiFi. Kalau PC konek lewat WiFi,
  adapter harus mendukung mode share WiFi-ke-WiFi (lihat pesan error kalau tidak).
- QR code dibuat lokal oleh aplikasi. SSID/password tidak dikirim ke internet.
- Windows kadang mematikan hotspot sendiri saat tidak ada perangkat yang konek;
  cukup klik **Aktifkan Hotspot** lagi.

## Mode command line

```powershell
powershell -ExecutionPolicy Bypass -File WifiShare.ps1 -Start    # nyalakan
powershell -ExecutionPolicy Bypass -File WifiShare.ps1 -Stop     # matikan
powershell -ExecutionPolicy Bypass -File WifiShare.ps1 -SelfTest # cek status adapter
```

## Kalau gagal

- **"Hotspot tidak bisa diaktifkan: diblokir oleh Group Policy"** — aktifkan
  Settings > Network & internet > Mobile hotspot (kalau di sana juga terkunci,
  berarti dibatasi oleh kebijakan organisasi).
- **"diblokir oleh hardware/driver"** — cek `netsh wlan show drivers`;
  driver harus mendukung Wi-Fi Direct / Mobile Hotspot dan adapter WiFi harus aktif.
- Update driver adapter WiFi biasanya menyelesaikan masalah kemampuan hotspot.
