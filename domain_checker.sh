#!/bin/bash

# Konfigurasi Bot Telegram
TELEGRAM_BOT_TOKEN="YOUR_BOT_TOKEN"
TELEGRAM_CHAT_ID="YOUR_CHAT_ID"
WORKDIR="/root/domains_checker" # Check it with pwd

DOMAIN_FILE="$WORKDIR/domain_list.txt"
LOG_FILE="$WORKDIR/domain_check.log"
PREV_LOG_FILE="$WORKDIR/domain_check_prev.log"
NOTIFICATION_FILE="$WORKDIR/notification_timestamps.txt"

# Fungsi untuk mengirim pesan ke Telegramr
send_telegram_message() {
    local message="$1"
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
         -d "chat_id=$TELEGRAM_CHAT_ID" \
         -d "text=$message" \
         -d "parse_mode=Markdown"
}

# Fungsi untuk memeriksa status domain dan menyimpannya ke log
check_domains() {
    > "$LOG_FILE"  # Kosongkan file log baru

    while IFS= read -r DOMAIN; do
        WHOIS_OUTPUT=$(whois "$DOMAIN")
        if echo "$WHOIS_OUTPUT" | grep -q "No match for"; then
            STATUS="Tersedia/Mati"
            REGISTRAR="N/A"
            REGISTRATION_URL="N/A"
            EXPIRATION_DATE="N/A"
            DAYS_UNTIL_EXPIRATION="N/A"
        else
            STATUS="Aktif"
            # REGISTRAR=$(echo "$WHOIS_OUTPUT" | grep -i -E "Registrar:|Registrar Organization:" | awk -F': ' '{print $2}' | xargs | head -n 1)
            REGISTRAR=$(echo "$WHOIS_OUTPUT" | awk -F': ' '/Registrar:|Registrar Organization:/ {print $2; exit}' | xargs)
            # REGISTRATION_URL=$(echo "$WHOIS_OUTPUT" | grep -i "Registrar URL:" | awk -F': ' '{print $2}' | xargs)
            REGISTRATION_URL=$(echo "$WHOIS_OUTPUT" | awk -F': ' '/Registrar URL:/ {print $2; exit}' | xargs)
            EXPIRATION_DATE=$(echo "$WHOIS_OUTPUT" | grep -i -E "Registry Expiry Date:|Expiration Date:" | awk -F': ' '{print $2}' | xargs | head -n 1 | awk '{print $1}' | cut -d'T' -f1)

            if [[ ! "$REGISTRATION_URL" =~ ^https?:// ]]; then
                    REGISTRATION_URL="https://$REGISTRATION_URL"
            fi
            if [ -n "$EXPIRATION_DATE" ]; then
                EXPIRATION_TIMESTAMP=$(date -d "$EXPIRATION_DATE" +%s 2>/dev/null)
                CURRENT_TIMESTAMP=$(date +%s)
                DAYS_UNTIL_EXPIRATION=$(( (EXPIRATION_TIMESTAMP - CURRENT_TIMESTAMP) / 86400 ))
            else
                EXPIRATION_DATE="N/A"
                DAYS_UNTIL_EXPIRATION="N/A"
            fi
        fi

        # Menyimpan hasil ke file log
        {
            echo "Nama Domain: $DOMAIN"
            echo "Status: $STATUS"
            echo "Registrasi: $REGISTRAR"
            echo "URL: $REGISTRATION_URL"
            echo "Tanggal Expired: $EXPIRATION_DATE"
            echo "Sisa Hari hingga Expired: $DAYS_UNTIL_EXPIRATION"
            echo "-------------------------------"
        } >> "$LOG_FILE"

        # Kirim notifikasi jika sisa hari hingga kadaluarsa
        notify_expiration "$DOMAIN" "$DAYS_UNTIL_EXPIRATION"

    done < "$DOMAIN_FILE"
}

notify_expiration() {
    local DOMAIN="$1"
    local DAYS="$2"
    local TODAY=$(date +%Y-%m-%d)

    # Cek apakah notifikasi sudah dikirim hari ini
    if [[ "$DAYS" =~ ^[0-9]+$ ]]; then
        LAST_NOTIFICATION_DATE=$(grep -E "^$DOMAIN " "$NOTIFICATION_FILE" | awk '{print $2}')

        # Simpan entri saat ini jika tidak ada notifikasi hari ini
        if [[ "$LAST_NOTIFICATION_DATE" != "$TODAY" ]]; then
            # Kirim notifikasi sesuai dengan DAYS
            if [ "$DAYS" -lt 4 ] || [ "$DAYS" -eq 7 ] || [ "$DAYS" -eq 30 ]; then
                send_telegram_message "⚠️ Domain *$DOMAIN* ⚠️%0AAkan kedaluwarsa dalam *$DAYS hari*! "
            fi

            # Hapus entri lama hanya jika ada
            if [[ -n "$LAST_NOTIFICATION_DATE" ]]; then
                sed -i "/^$DOMAIN /d" "$NOTIFICATION_FILE"  # Hapus entri lama
            fi

            # Tambah entri baru
            echo "$DOMAIN $TODAY" >> "$NOTIFICATION_FILE"
        fi
    fi
}

notify_day_increase() {
    local DOMAIN="$1"
    local OLD_DAYS="$2"
    local NEW_DAYS="$3"
    
    if [[ "$OLD_DAYS" =~ ^[0-9]+$ ]] && [[ "$NEW_DAYS" =~ ^[0-9]+$ ]]; then
        local DIFF=$(( NEW_DAYS - OLD_DAYS ))
        
        if [ "$DIFF" -gt 0 ]; then
            local TOTAL_DAYS=$(( OLD_DAYS + DIFF ))
            send_telegram_message "✅ *$DOMAIN* ✅%0AMengalami perpanjangan *$DIFF hari*%0ADan total sisa hari hingga kadaluarsa adalah *$TOTAL_DAYS hari*!"
        fi
    fi
}

# Fungsi untuk membandingkan log dan mengirim notifikasi jika ada perubahan
compare_logs() {
    if [ -f "$PREV_LOG_FILE" ]; then
        ADDED_DOMAINS=$(grep -F -x -v -f "$PREV_LOG_FILE" "$LOG_FILE" | grep "Nama Domain:" | awk -F': ' '{print $2}')
        REMOVED_DOMAINS=$(grep -F -x -v -f "$LOG_FILE" "$PREV_LOG_FILE" | grep "Nama Domain:" | awk -F': ' '{print $2}')

        # Kirim pesan jika ada penambahan domain
        if [ -n "$ADDED_DOMAINS" ]; then
            send_telegram_message "📋 Domain yang ditambahkan ✅%0A*$ADDED_DOMAINS*"
        fi

        # Kirim pesan jika ada pengurangan domain
        if [ -n "$REMOVED_DOMAINS" ]; then
            send_telegram_message "📋 Domain yang dihapus ❌%0A*$REMOVED_DOMAINS*"
        fi

        # Periksa penambahan hari untuk domain yang ada
        while IFS= read -r DOMAIN; do
            OLD_DAYS=$(grep -A 5 "$DOMAIN" "$PREV_LOG_FILE" | grep "Sisa Hari hingga Expired:" | cut -d':' -f2 | xargs)
            NEW_DAYS=$(grep -A 5 "$DOMAIN" "$LOG_FILE" | grep "Sisa Hari hingga Expired:" | cut -d':' -f2 | xargs)
            
            notify_day_increase "$DOMAIN" "$OLD_DAYS" "$NEW_DAYS"
        done < <(grep "Nama Domain:" "$LOG_FILE")
    else
        echo "Tidak ada log sebelumnya untuk dibandingkan."
    fi
}

create_and_send_csv() {
    local TODAY=$(date +%Y-%m-%d)
    local LAST_CSV_MONTH=$(grep -E "^csv_sent " "$NOTIFICATION_FILE" | awk '{print $2}')
    
    if [[ -z "$LAST_CSV_MONTH" ]] || [[ "$(date -d "$TODAY" +%m)" != "$(date -d "$LAST_CSV_MONTH" +%m)" ]] || [[ "$(date -d "$TODAY" +%Y)" != "$(date -d "$LAST_CSV_MONTH" +%Y)" ]]; then
        local CSV_FILE="$WORKDIR/domain_report_$TODAY.csv"
        echo "Nama Domain,Status,Registrasi,URL Registrasi,Tanggal Expired,Sisa Hari hingga Expired" > "$CSV_FILE"

        while IFS= read -r DOMAIN; do
            DOMAIN_INFO=$(grep -A 5 "$DOMAIN" "$LOG_FILE")

            # Ambil masing-masing informasi dengan benar
            local STATUS=$(echo "$DOMAIN_INFO" | grep "Status:" | cut -d':' -f2- | xargs)
            local REGISTRASI=$(echo "$DOMAIN_INFO" | grep "Registrasi:" | cut -d':' -f2 | xargs)
            local URL=$(echo "$DOMAIN_INFO" | grep "URL:" | cut -d':' -f2- | xargs)
            local TANGGAL_EXPIRED=$(echo "$DOMAIN_INFO" | grep "Tanggal Expired:" | cut -d':' -f2- | xargs)
            local SISA_HARI=$(echo "$DOMAIN_INFO" | grep "Sisa Hari hingga Expired:" | cut -d':' -f2- | xargs)

            # Tulis ke file CSV
            echo "$DOMAIN,$STATUS,\"$REGISTRASI\",$URL,$TANGGAL_EXPIRED,$SISA_HARI" >> "$CSV_FILE"
        done < "$DOMAIN_FILE"

        send_telegram_message "📊 Laporan domain terbaru telah dibuat dan dilampirkan."
        curl -F document=@"$CSV_FILE" "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$TELEGRAM_CHAT_ID"

        sed -i "/^csv_sent /d" "$NOTIFICATION_FILE"
        echo "csv_sent $TODAY" >> "$NOTIFICATION_FILE"
    fi
}

send_help_message() {
    local CHAT_ID=$1
    local MESSAGE="🆘 *Daftar Perintah:*%0A"
    MESSAGE+="1. /fulldomain - Menampilkan daftar semua domain terdaftar.%0A"
    MESSAGE+="2. /detailsdomain <domain> - Menampilkan detail untuk domain tertentu.%0A"
    MESSAGE+="3. /downloadcsv - Mengunduh daftar domain dalam format CSV.%0A"
    MESSAGE+="%0AGunakan perintah di atas untuk mendapatkan informasi lebih lanjut."
    
    send_telegram_message "$MESSAGE"
}

send_full_domain_list() {
    if [ -f "$LOG_FILE" ]; then
        local DOMAIN_LIST=$(grep "Nama Domain:" "$LOG_FILE" | awk -F': ' '{print $2}' | xargs -n 1 echo)
        if [ -n "$DOMAIN_LIST" ]; then
            # Menambahkan nomor pada setiap domain
            local NUMBERED_DOMAIN_LIST=$(echo "$DOMAIN_LIST" | nl -w 2 -s '. ')
            send_telegram_message "📋 Daftar Domain:%0A$NUMBERED_DOMAIN_LIST"
        else
            send_telegram_message "❌ Tidak ada domain yang terdaftar."
        fi
    else
        send_telegram_message "❌ File log tidak ditemukan."
    fi
}

send_domain_details() {
    local DOMAIN=$1
    if [ -f "$LOG_FILE" ]; then
        local DOMAIN_INFO=$(grep -A 5 "$DOMAIN" "$LOG_FILE")
        if [ -n "$DOMAIN_INFO" ]; then
            # Ambil masing-masing informasi dengan benar
            local STATUS=$(echo "$DOMAIN_INFO" | grep "Status:" | cut -d':' -f2- | xargs)
            local REGISTRASI=$(echo "$DOMAIN_INFO" | grep "Registrasi:" | cut -d':' -f2 | xargs)
            local URL=$(echo "$DOMAIN_INFO" | grep "URL:" | cut -d':' -f2- | xargs)
            local TANGGAL_EXPIRED=$(echo "$DOMAIN_INFO" | grep "Tanggal Expired:" | cut -d':' -f2- | xargs)
            local SISA_HARI=$(echo "$DOMAIN_INFO" | grep "Sisa Hari hingga Expired:" | cut -d':' -f2- | xargs)

            # Siapkan pesan untuk dikirim
            local MESSAGE="📄 Detail Domain: $DOMAIN%0A"
            MESSAGE+="Status: $STATUS%0A"
            MESSAGE+="Registrasi: $REGISTRASI%0A"
            MESSAGE+="URL: $URL%0A"
            MESSAGE+="Tanggal Expired: $TANGGAL_EXPIRED%0A"
            MESSAGE+="Sisa Hari hingga Expired: $SISA_HARI%0A"

            send_telegram_message "$MESSAGE"
        else
            send_telegram_message "❌ Detail untuk domain '$DOMAIN' tidak ditemukan."
        fi
    else
        send_telegram_message "❌ File log tidak ditemukan."
    fi
}

send_csv_download() {
    if [ -f "$LOG_FILE" ]; then
        local CSV_FILE="domain_list.csv"

        # Write header to CSV file
        echo "Domain,Status,Registrasi,URL,Tanggal Expired,Sisa Hari hingga Expired" > "$CSV_FILE"

        # Add data to CSV file
        grep "Nama Domain:" "$LOG_FILE" | while read -r line; do
            local DOMAIN=$(echo "$line" | awk -F': ' '{print $2}' | xargs)
            local DOMAIN_INFO=$(grep -A 5 "$DOMAIN" "$LOG_FILE")

            # Get each piece of information
            local STATUS=$(echo "$DOMAIN_INFO" | grep "Status:" | cut -d':' -f2- | xargs)
            local REGISTRASI=$(echo "$DOMAIN_INFO" | grep "Registrasi:" | cut -d':' -f2 | xargs)
            local URL=$(echo "$DOMAIN_INFO" | grep "URL:" | cut -d':' -f2- | xargs)
            local TANGGAL_EXPIRED=$(echo "$DOMAIN_INFO" | grep "Tanggal Expired:" | cut -d':' -f2- | xargs)
            local SISA_HARI=$(echo "$DOMAIN_INFO" | grep "Sisa Hari hingga Expired:" | cut -d':' -f2- | xargs)

            # Write data to CSV
            echo "$DOMAIN,$STATUS,$REGISTRASI,$URL,$TANGGAL_EXPIRED,$SISA_HARI" >> "$CSV_FILE"
        done

        # Send CSV file to Telegram with a caption
        local CAPTION="📊 Berikut adalah daftar domain dalam format CSV:"
        send_telegram_file "$CSV_FILE" "$CHAT_ID" "$CAPTION"

        # Delete CSV file after sending
        rm "$CSV_FILE"
    else
        send_telegram_message "❌ File log tidak ditemukan."
    fi
}

send_telegram_file() {
    local FILE_PATH=$1
    local CHAT_ID=$2
    local CAPTION=$3
    curl -s -X POST "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendDocument" -F chat_id="$CHAT_ID" -F document=@"$FILE_PATH" -F caption="$CAPTION"
}

process_telegram_commands() {
    local LAST_UPDATE_ID
    LAST_UPDATE_ID=$(grep -E '^[0-9]+$' "$NOTIFICATION_FILE" | tail -n 1)

    # Pastikan LAST_UPDATE_ID adalah angka
    if ! [[ "$LAST_UPDATE_ID" =~ ^[0-9]+$ ]]; then
        LAST_UPDATE_ID=0  # Atur ke 0 jika bukan angka
    fi

    local UPDATES
    UPDATES=$(curl -s -X GET "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates?offset=$((LAST_UPDATE_ID + 1))&timeout=30")

    echo "$UPDATES" | jq -c '.result[]?' | while read -r update; do
        local CHAT_ID
        CHAT_ID=$(echo "$update" | jq '.message.chat.id')
        local MESSAGE_TEXT
        MESSAGE_TEXT=$(echo "$update" | jq -r '.message.text')
        local UPDATE_ID
        UPDATE_ID=$(echo "$update" | jq '.update_id')

        if [ "$UPDATE_ID" -gt "$LAST_UPDATE_ID" ]; then
            LAST_UPDATE_ID=$UPDATE_ID

            # Periksa perintah /fulldomain
            if [[ "$MESSAGE_TEXT" == "/fulldomain" ]]; then
                send_full_domain_list "$CHAT_ID"
            # Periksa perintah /details_domain
            elif [[ "$MESSAGE_TEXT" == /detailsdomain\ *(*) ]]; then
                local DOMAIN=$(echo "$MESSAGE_TEXT" | awk '{print $2}')
                if [ -n "$DOMAIN" ]; then
                    send_domain_details "$DOMAIN"
                else
                    send_telegram_message "❌ Silakan berikan nama domain setelah perintah."
                fi
            # Periksa perintah /download_csv
            elif [[ "$MESSAGE_TEXT" == "/downloadcsv" ]]; then
                send_csv_download "$CHAT_ID"
            elif [[ "$MESSAGE_TEXT" == "/help" ]]; then
                send_help_message "$CHAT_ID"
            fi
            
            # Memperbarui LAST_UPDATE_ID di NOTIFICATION_FILE
            if grep -q '^[0-9]\+$' "$NOTIFICATION_FILE"; then
                # Jika ada ID yang ditemukan, ganti
                sed -i "s/^[0-9]\+/$LAST_UPDATE_ID/" "$NOTIFICATION_FILE"
            else
                # Jika tidak ada, tambahkan ID baru
                echo "$LAST_UPDATE_ID" >> "$NOTIFICATION_FILE"
            fi
        fi
    done
}

# Salin file log sebelumnya jika ada
if [ -f "$LOG_FILE" ]; then
    cp "$LOG_FILE" "$PREV_LOG_FILE"
else
    touch "$PREV_LOG_FILE"  # Buat file kosong jika tidak ada
fi

# Memeriksa domain
check_domains

# Bandingkan log dan kirim notifikasi
compare_logs

# Panggil fungsi untuk membuat dan mengirim CSV
create_and_send_csv

# Proses perintah Telegram
process_telegram_commands

echo "Hasil pemeriksaan domain telah disimpan di $LOG_FILE."
