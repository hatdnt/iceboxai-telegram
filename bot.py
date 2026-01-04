import os
import logging
import requests
import asyncio
from datetime import datetime, timezone, timedelta
from dotenv import load_dotenv
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes, ConversationHandler
from supabase import create_client, Client

# Load environment variables
load_dotenv()

# Configuration
TELEGRAM_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
SUPABASE_URL = os.getenv("SUPABASE_URL")
SUPABASE_KEY = os.getenv("SUPABASE_KEY")

# Logging setup
logging.basicConfig(
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s", level=logging.INFO
)
logger = logging.getLogger(__name__)

# Supabase Client
supabase: Client = create_client(SUPABASE_URL, SUPABASE_KEY)

# States for ConversationHandler
WAITING_FOR_PROMPT = 1
WAITING_FOR_SIZE = 2

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Send a message when the command /start is issued."""
    user = update.effective_user
    chat_id = update.effective_chat.id
    
    # Register/Update user in Supabase
    try:
        data = {
            "p_chat_id": chat_id,
            "p_username": user.username,
            "p_first_name": user.first_name,
            "p_last_name": user.last_name,
            "p_language_code": user.language_code,
            "p_is_bot": user.is_bot
        }
        supabase.rpc("upsert_telegram_user", data).execute()
        logger.info(f"User {user.id} upserted to Supabase")
    except Exception as e:
        logger.error(f"Error upserting user: {e}")

    await show_main_menu(update, context)


import io
from http.server import HTTPServer, BaseHTTPRequestHandler
from threading import Thread

# Dummy Server for Hugging Face Health Check (Port 7860)
class HealthCheckHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"Bot is running")

def run_health_server():
    port = 7860
    server = HTTPServer(("0.0.0.0", port), HealthCheckHandler)
    print(f"Health check server running on port {port}")
    server.serve_forever()

def main():
    """Start the bot."""
    # Start health check server in background
    Thread(target=run_health_server, daemon=True).start()

    if not TELEGRAM_TOKEN:
        print("Error: TELEGRAM_BOT_TOKEN not found.")
        return

    # Support for custom API URL (Proxy)
    base_url = os.getenv("TELEGRAM_API_BASE_URL")
    base_file_url = os.getenv("TELEGRAM_API_FILE_URL")
    
    builder = Application.builder().token(TELEGRAM_TOKEN)
    
    if base_url:
        builder.base_url(base_url)
        print(f"Using Custom API URL: {base_url}")
        
    if base_file_url:
        builder.base_file_url(base_file_url)

    application = builder.build()

    # Conversation handler for generating commands
    conv_handler = ConversationHandler(
        entry_points=[CallbackQueryHandler(enter_generate_mode, pattern="^generate_mode$")],
        states={
            WAITING_FOR_PROMPT: [MessageHandler(filters.TEXT & ~filters.COMMAND, handle_prompt)],
            WAITING_FOR_SIZE: [CallbackQueryHandler(handle_size_selection)],
        },
        fallbacks=[CommandHandler("start", start), CallbackQueryHandler(show_main_menu, pattern="^main_menu$")]
    )

    application.add_handler(CommandHandler("start", start))
    application.add_handler(conv_handler)
    
    # Menu callbacks
    application.add_handler(CallbackQueryHandler(show_main_menu, pattern="^main_menu$"))
    application.add_handler(CallbackQueryHandler(show_profile, pattern="^profile$"))
    
    application.add_handler(CallbackQueryHandler(show_help, pattern="^help$"))

    # Run the bot
    print("Bot is running...")
    application.run_polling()

async def show_main_menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Displays the main menu with inline buttons."""
    user = update.effective_user
    # Use @username if available, otherwise fallback to first_name
    if user.username:
        username = f"@{user.username}"
    else:
        username = user.first_name if user.first_name else "User"
    
    # "Koin" instead of Tokens. Emotes reduced. Professional tone.
    # Topup hidden.
    keyboard = [
        [InlineKeyboardButton("Generate Image", callback_data="generate_mode")],
        [InlineKeyboardButton("My Profile", callback_data="profile")], # Removed Upgrade
        [InlineKeyboardButton("Help & Support", callback_data="help")]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    text = (
        f"Hi {username}, welcome to the @iceboxai\\_bot.\n\n"
        "✨ **What you can create:**\n"
        "• Realistic photos\n"
        "• Anime & illustration\n"
        "• Cinematic portraits\n"
        "• Fantasy & concept art\n"
        "• Logos & product visuals\n\n"
        "Choose an option below to get started 👇"
    )

    if update.callback_query:
        await update.callback_query.answer()
        # Ensure we don't crash if message is not modified
        try:
            await update.callback_query.edit_message_text(text=text, reply_markup=reply_markup, parse_mode="Markdown")
        except:
             await update.callback_query.message.reply_text(text, reply_markup=reply_markup, parse_mode="Markdown")
    else:
        await update.message.reply_text(text, reply_markup=reply_markup, parse_mode="Markdown")
    
    return ConversationHandler.END

async def enter_generate_mode(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Ask user for prompt."""
    query = update.callback_query
    await query.answer()
    
    keyboard = [[InlineKeyboardButton("Back to Menu", callback_data="main_menu")]]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await query.edit_message_text(
        text="**Enter your prompt:**",
        reply_markup=reply_markup,
        parse_mode="Markdown"
    )
    return WAITING_FOR_PROMPT

async def handle_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Process the image prompt and ask for size."""
    prompt = update.message.text
    
    if prompt.lower() in ['/start', 'cancel']:
        await start(update, context)
        return ConversationHandler.END

    # Save prompt to context
    context.user_data['prompt'] = prompt
    
    # Show Size Options
    keyboard = [
        [InlineKeyboardButton("Square (1:1)", callback_data="size_1024x1024"), InlineKeyboardButton("Portrait (3:4)", callback_data="size_1024x1280")],
        [InlineKeyboardButton("Landscape (4:3)", callback_data="size_1280x1024"), InlineKeyboardButton("Wide (16:9)", callback_data="size_1280x720")],
        [InlineKeyboardButton("Back", callback_data="main_menu")]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await update.message.reply_text(
        "**Select Aspect Ratio**\n\nChoose the size for your image:",
        reply_markup=reply_markup,
        parse_mode="Markdown"
    )
    return WAITING_FOR_SIZE

async def handle_size_selection(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Execute generation with selected size."""
    query = update.callback_query
    await query.answer()
    
    data = query.data
    
    if data == "main_menu":
        await show_main_menu(update, context)
        return ConversationHandler.END
        
    # Parse size "size_WxH"
    try:
        size_str = data.split("_")[1]
        width, height = size_str.split("x")
    except:
        width, height = "1024", "1280" # Fallback

    prompt = context.user_data.get('prompt', '')
    chat_id = update.effective_chat.id
    
    status_msg = await query.edit_message_text(f"Processing request for `{prompt}`...", parse_mode="Markdown")

    try:
        # Get user UUID
        user_response = supabase.table("telegram_users").select("id").eq("chat_id", chat_id).execute()
        if not user_response.data:
             await status_msg.edit_text("Error: User record not found. Type /start to reset.")
             return ConversationHandler.END
        
        user_uuid = user_response.data[0]['id']
        
        # Check limits
        check = supabase.rpc("can_generate_image", {"p_user_id": user_uuid}).execute()
        result = check.data[0]
        
        if not result['can_generate']:
            await status_msg.edit_text(
                f"Request Denied.\nReason: {result['reason']}",
                reply_markup=InlineKeyboardMarkup([[InlineKeyboardButton("Back via Menu", callback_data="main_menu")]])
            )
            return ConversationHandler.END
        
        # Generate
        await status_msg.edit_text(f"Generating image ({size_str})...\nPlease wait...", parse_mode="Markdown")
        
        api_key = os.getenv("POLLINATIONS_KEY", "")
        seed = int(datetime.now().timestamp() * 1000) % 100000
        image_url = f"https://gen.pollinations.ai/image/{prompt}?model=zimage&width={width}&height={height}&seed={seed}"
        if api_key:
            image_url += f"&key={api_key}"
        
        response = requests.get(image_url)
        if response.status_code == 200:
            # Process & Deduct
            log_data = {
                "p_user_id": user_uuid,
                "p_chat_id": chat_id,
                "p_prompt": prompt,
                "p_model_used": "zimage",
                "p_image_size": size_str,
                "p_seed": seed,
                "p_generation_time_ms": int(response.elapsed.total_seconds() * 1000)
            }
            # RPC handles deduction and returns new stats
            log_res = supabase.rpc("process_image_generation", log_data).execute()
            log_info = log_res.data[0]
            
            # Delete status message so clean chat
            await status_msg.delete()
            
            # 1. Send ID Photo (Clean)
            await context.bot.send_photo(
                chat_id=chat_id,
                photo=io.BytesIO(response.content)
            )
            
             # 2. Send Separate Info/Menu Message
            if log_info['tier_used'] == 'free':
                recheck = supabase.rpc("can_generate_image", {"p_user_id": user_uuid}).execute()
                rem = recheck.data[0]
                limit_status = f"`{rem['daily_remaining']}` generations remaining today"
                
                # Calculate next reset time (07:00 WIB / 00:00 UTC)
                now_utc = datetime.now(timezone.utc)
                today_reset = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
                if now_utc >= today_reset:
                    next_reset = today_reset + timedelta(days=1)
                else:
                    next_reset = today_reset
                reset_time = f"{next_reset.strftime('%Y-%m-%d')} 07:00 WIB"
            else:
                 limit_status = f"`{log_info['tokens_remaining']}` Koin remaining"
                 reset_time = "Never (Paid)"

            info_text = (
                f"✅ **Generation Complete!**\n\n"
                f"**Daily Limit Status**\n"
                f"{limit_status}\n\n"
                f"⏰ **Limit will reset at:**\n"
                f"`{reset_time}`"
            )
            
            keyboard = [
                [InlineKeyboardButton("Generate Again", callback_data="generate_mode")],
                [InlineKeyboardButton("Back to Home", callback_data="main_menu")]
            ]
            
            await context.bot.send_message(
                chat_id=chat_id,
                text=info_text,
                reply_markup=InlineKeyboardMarkup(keyboard),
                parse_mode="Markdown"
            )
            
        else:
            await status_msg.edit_text("Generation failed due to provider error.")

    except Exception as e:
        logger.error(f"Error generation: {e}")
        await status_msg.edit_text(f"System error: {str(e)}")

    return ConversationHandler.END

async def show_profile(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show detailed user profile."""
    query = update.callback_query
    await query.answer()
    
    chat_id = update.effective_chat.id
    
    try:
        # Get basic user data
        res = supabase.table("telegram_users").select("*").eq("chat_id", chat_id).execute()
        if not res.data:
            await query.edit_message_text("Profile not found.")
            return

        u = res.data[0]
        user_uuid = u['id']

        # Get detailed limits via RPC
        check = supabase.rpc("can_generate_image", {"p_user_id": user_uuid}).execute()
        status = check.data[0] # contains daily_remaining, montly_remaining
        
        # Determine Status Text
        tier_display = "Free" if u.get('tier') == 'free' else "Premium"
        status_display = u.get('status', 'active').capitalize()
        
        # Calculate limits
        daily_used = u.get('daily_images_generated', 0)
        daily_rem = status['daily_remaining']
        daily_total = daily_used + daily_rem
        
        # Calculate next reset time (07:00 WIB / 00:00 UTC)
        now_utc = datetime.now(timezone.utc)
        today_reset = now_utc.replace(hour=0, minute=0, second=0, microsecond=0)
        if now_utc >= today_reset:
            next_reset = today_reset + timedelta(days=1)
        else:
            next_reset = today_reset
        reset_display = next_reset.strftime('%Y-%m-%d')
        total_gen = u.get('total_images_generated', 0)
        
        # Monospace format
        text = (
            f"```\n"
            f"Name            : {u.get('first_name', 'User')}\n\n"
            f"ID              : {chat_id}\n"
            f"Region          : {u.get('language_code', 'en')}\n"
            f"Tier            : {tier_display}\n"
            f"Status          : {status_display}\n\n"
            f"Activity\n"
            f"Total Generated : {total_gen}\n\n"
            f"Ussage\n"
        )
        
        if u.get('tier') == 'paid':
             text += f"Balance         : {u.get('token_balance', 0)} Koin\n"
        else:
             text += f"Daily Limit     : {daily_used} / {daily_total}\n"
             text += f"Reset Limit     : {reset_display} 07:00 WIB\n"
        
        text += "```"
        
        keyboard = [[InlineKeyboardButton("🔙 Back to Menu", callback_data="main_menu")]]
        await query.edit_message_text(text=text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode="Markdown")
        
    except Exception as e:
        logger.error(f"Profile error: {e}")
        await query.edit_message_text("Could not load profile.")

async def show_help(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Show help and contact."""
    query = update.callback_query
    await query.answer()
    
    text = (
        "**Help & Support**\n\n"
        "If you encounter any issues or have questions, please contact our admin:\n"
        "📩 Contact: @pinturusak\n"
    )
    
    keyboard = [[InlineKeyboardButton("Back to Menu", callback_data="main_menu")]]
    await query.edit_message_text(text=text, reply_markup=InlineKeyboardMarkup(keyboard), parse_mode="Markdown")

if __name__ == "__main__":
    main()
