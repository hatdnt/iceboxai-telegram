# 🎨 Icebox AI - Telegram Image Generator Bot

![Python](https://img.shields.io/badge/Python-3.10-blue?style=for-the-badge&logo=python&logoColor=white)
![Telegram](https://img.shields.io/badge/Telegram-Bot-2CA5E0?style=for-the-badge&logo=telegram&logoColor=white)
![Supabase](https://img.shields.io/badge/Supabase-Database-3ECF8E?style=for-the-badge&logo=supabase&logoColor=white)
![Hugging Face](https://img.shields.io/badge/Hugging%20Face-Spaces-FFD21E?style=for-the-badge&logo=huggingface&logoColor=black)

**Icebox AI** is a powerful yet easy-to-use Telegram bot that allows users to generate stunning AI images directly from their chat. Powered by the **Pollinations AI** engine and managed via **Supabase**, this project demonstrates a robust implementation of a freemium AI service with daily limits, user tracking, and premium tier capabilities.

🚀 **Deploy your own AI art community today!**

---

## ✨ Key Features

*   **⚡ Instant Generation**: Generates high-quality images in seconds using the `zimage` model.
*   **📐 Multi-Aspect Ratios**: Supports Square (1:1), Portrait (3:4), Landscape (4:3), and Wide (16:9) formats.
*   **👤 Comprehensive User Profile**: Tracks user activity, detailed usage statistics, and tier status (Free/Premium).
*   **🛡️ Smart Rate Limiting**: Intelligent daily limit system reset automatically at 07:00 WIB (UTC+7).
*   **💳 Tier System**: Built-in support for multiple user tiers (Free vs. Koin/Premium).
*   **🐳 Docker Ready**: Fully containerized for easy deployment on Hugging Face Spaces or any VPS.
*   **☁️ Cloud-Native Database**: Utilizes Supabase for scalable user management and logging.

---

## 📸 Screenshots

| Main Menu | Aspect Selection | Generation Result | User Profile |
|:---:|:---:|:---:|:---:|
| *(Place screenshot here)* | *(Place screenshot here)* | *(Place screenshot here)* | *(Place screenshot here)* |

---

## 🛠️ Tech Stack

*   **Language**: Python 3.10+
*   **Framework**: `python-telegram-bot` (Async)
*   **Database**: Supabase (PostgreSQL)
*   **AI Provider**: Pollinations AI
*   **Deployment**: Docker / Hugging Face Spaces

---

## 🚀 Getting Started

### Prerequisites

1.  **Telegram Bot Token**: Get one from [@BotFather](https://t.me/BotFather).
2.  **Supabase Account**: Create a project at [supabase.com](https://supabase.com).
3.  **Pollinations AI**: (Optional) API key if you need higher limits, though the base model is free.

### Local Installation

1.  **Clone the Repository**
    ```bash
    git clone https://github.com/Start-Icebox/icebox-ai-bot.git
    cd icebox-ai-bot
    ```

2.  **Install Dependencies**
    ```bash
    pip install -r requirements.txt
    ```

3.  **Environment Configuration**
    Create a `.env` file in the root directory:
    ```env
    TELEGRAM_BOT_TOKEN=your_telegram_bot_token
    SUPABASE_URL=your_supabase_project_url
    SUPABASE_KEY=your_supabase_anon_key
    TELEGRAM_API_BASE_URL=  # Optional: For local bot API server
    TELEGRAM_API_FILE_URL=  # Optional: For local bot API server
    POLLINATIONS_KEY=       # Optional: Your Pollinations.ai API Key
    ```

4.  **Database Setup (Supabase)**
    Run the SQL scripts in your Supabase SQL Editor to create the necessary tables and functions.
    *   *See `supabase schema.txt` (if available) or check `fix_rpc.sql` for core functions.*
    *   **Core Tables**: `telegram_users`, `generation_logs`.
    *   **RPC Functions**: `upsert_telegram_user`, `can_generate_image`, `process_image_generation`.

5.  **Run the Bot**
    ```bash
    python bot.py
    ```

---

## 🐳 Deployment (Hugging Face Spaces)

This bot is optimized for **Hugging Face Spaces** (Docker SDK).

1.  Create a new Space on Hugging Face.
2.  Select **Docker** as the SDK.
3.  Upload the files from this repository.
4.  Go to **Settings** > **Variables and secrets** and add your secrets:
    *   `TELEGRAM_BOT_TOKEN`
    *   `SUPABASE_URL`
    *   `SUPABASE_KEY`
5.   The bot runs a health check server on port `7860` to keep the Space active.

---

## 🤝 Application for Pollinations AI Tier

This project is actively maintained and aims to provide a high-quality (accessible) AI generation tool for the telegram community. We are applying for a higher tier to:
*   **Increase Stability**: Reduce rate limits for our growing user base.
*   **Enhance Quality**: Access faster and more consistent generation pipelines.
*   **Community Growth**: Support more daily requests for our dedicated users.

---

## 📜 License

Distributed under the MIT License. See `LICENSE` for more information.

---

**Built with 💙 by hatdnt**
