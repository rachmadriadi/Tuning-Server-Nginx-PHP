# 🚀 Tuning Server Nginx/PHP

A comprehensive bash script for optimizing Nginx, PHP-FPM, and Linux kernel parameters for high-traffic web servers.

---

## ✨ Core Features

- **Kernel Tuning**  
  Optimizes Linux kernel network stack parameters for high concurrency and throughput.

- **Nginx & PHP-FPM Configuration**  
  Adjusts worker processes and connection settings for optimal performance.

- **Automated Backups**  
  Automatically backs up all modified configuration files before applying changes.

- **One-Command Rollback**  
  Generates a `rollback.sh` script to instantly revert all changes.

- **Cross-Distribution Support**  
  Supports Debian/Ubuntu and RHEL/CentOS/Fedora-based systems.

- **Idempotent**  
  Safe to run multiple times — only applies necessary changes.

---

## ⚠️ IMPORTANT DISCLAIMER

> This script modifies critical system-level configuration files such as `/etc/sysctl.conf` and service configs for Nginx and PHP-FPM. These changes can significantly impact server performance and stability.

- **Do not** run this script on a production server without first testing in a staging or development environment.
- Review the **Parameters Explained** section before applying any changes.
- Use at your own risk. The authors are not responsible for data loss or downtime caused by this script.

---

## 📋 Prerequisites

- Linux system (Debian/Ubuntu or RHEL/CentOS/Fedora/Rocky/AlmaLinux)
- Nginx and PHP-FPM must be installed
- Root or sudo privileges are required

---

## 🛠️ Usage

### 1. Clone the repository

```bash
git clone https://github.com/rachmadriadi/Tuning-Server-Nginx-PHP.git
cd Tuning-Server-Nginx-PHP
```
## Make the script executable
```bash
chmod +x tune.sh
```
## ✅ Check Mode (Dry Run)
```bash
sudo ./tune.sh --check
```
## ⚙️ Apply Mode
```bash
sudo ./tune.sh --apply
```
## 🤝 Contributing
Contributions are welcome! Whether it's reporting a bug, suggesting an improvement, or submitting a pull request — your help is appreciated.

Please see [CONTRIBUTING.md](https://github.com/rachmadriadi/Tuning-Server-Nginx-PHP/blob/master/CONTRIBUTING.md) for guidelines.

## 📄 License
This project is licensed under the MIT License.




