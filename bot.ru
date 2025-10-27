import os
import logging
import sqlite3
from datetime import datetime, date
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
from openai import OpenAI

# Настройка логов
logging.basicConfig(format='%(asctime)s - %(name)s - %(levelname)s - %(message)s', level=logging.INFO)
logger = logging.getLogger(__name__)

# Берем ключи из переменных окружения (их настроим позже)
TELEGRAM_BOT_TOKEN = os.getenv('TELEGRAM_BOT_TOKEN')
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')

# Лимиты
FREE_DAILY_TEXT_LIMIT = 15
FREE_DAILY_IMAGE_LIMIT = 5

client = OpenAI(api_key=OPENAI_API_KEY)

# База данных
def init_db():
    conn = sqlite3.connect('bot_database.db')
    cursor = conn.cursor()
    cursor.execute('''
        CREATE TABLE IF NOT EXISTS users (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id INTEGER UNIQUE,
            username TEXT,
            daily_text_used INTEGER DEFAULT 0,
            daily_image_used INTEGER DEFAULT 0,
            last_reset_date TEXT,
            subscription_type TEXT DEFAULT 'free',
            subscription_end TEXT,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP
        )
    ''')
    conn.commit()
    conn.close()

def get_user(user_id, username=None):
    conn = sqlite3.connect('bot_database.db')
    cursor = conn.cursor()
    today = date.today().isoformat()
    
    cursor.execute('''
        INSERT OR IGNORE INTO users (user_id, username, last_reset_date) 
        VALUES (?, ?, ?)
    ''', (user_id, username, today))
    
    cursor.execute('''
        UPDATE users SET username = ? 
        WHERE user_id = ? AND username != ?
    ''', (username, user_id, username))
    
    cursor.execute('''
        UPDATE users 
        SET daily_text_used = 0, daily_image_used = 0, last_reset_date = ?
        WHERE user_id = ? AND last_reset_date != ?
    ''', (today, user_id, today))
    
    cursor.execute('SELECT * FROM users WHERE user_id = ?', (user_id,))
    user = cursor.fetchone()
    conn.commit()
    conn.close()
    return user

def update_user_usage(user_id, usage_type):
    conn = sqlite3.connect('bot_database.db')
    cursor = conn.cursor()
    if usage_type == 'text':
        cursor.execute('UPDATE users SET daily_text_used = daily_text_used + 1 WHERE user_id = ?', (user_id,))
    elif usage_type == 'image':
        cursor.execute('UPDATE users SET daily_image_used = daily_image_used + 1 WHERE user_id = ?', (user_id,))
    conn.commit()
    conn.close()

def check_limits(user):
    user_id, username, text_used, image_used, last_reset, sub_type, sub_end, created = user
    is_premium = False
    if sub_end and datetime.strptime(sub_end, '%Y-%m-%d').date() >= date.today():
        is_premium = True
    
    text_limit = 9999 if is_premium else FREE_DAILY_TEXT_LIMIT
    image_limit = 9999 if is_premium else FREE_DAILY_IMAGE_LIMIT
    
    return {
        'text_remaining': max(0, text_limit - text_used),
        'image_remaining': max(0, image_limit - image_used),
        'is_premium': is_premium
    }

# Клавиатура для подписки
def get_subscription_keyboard():
    keyboard = [
        [InlineKeyboardButton("💰 Неделя - 299 руб.", callback_data="sub_week")],
        [InlineKeyboardButton("💎 Месяц - 899 руб.", callback_data="sub_month")],
        [InlineKeyboardButton("🚀 3 месяца - 1999 руб.", callback_data="sub_3months")],
        [InlineKeyboardButton("❌ Закрыть", callback_data="close")]
    ]
    return InlineKeyboardMarkup(keyboard)

# Команды бота
async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_data = get_user(user.id, user.username)
    limits = check_limits(user_data)
    
    welcome_text = f"""
👋 Привет, {user.first_name}!

🤖 Я — AI-ассистент с ChatGPT и DALL-E!

📊 Ваши лимиты на сегодня:
• Текстовых запросов: {limits['text_remaining']}/15
• Генераций изображений: {limits['image_remaining']}/5

{'⭐ У вас активна ПРЕМИУМ подписка! ⭐' if limits['is_premium'] else ''}

Команды:
/chat [вопрос] - Задать вопрос
/image [описание] - Создать изображение  
/stats - Ваша статистика
/subscribe - Премиум подписка
"""
    await update.message.reply_text(welcome_text)

async def stats(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_data = get_user(user.id, user.username)
    limits = check_limits(user_data)
    
    stats_text = f"""
📊 Ваша статистика:

Текстовые запросы:
{limits['text_remaining']} из 15 осталось

Генерации изображений:
{limits['image_remaining']} из 5 осталось

Статус: {'⭐ ПРЕМИУМ' if limits['is_premium'] else '🎫 БЕСПЛАТНЫЙ'}
"""
    await update.message.reply_text(stats_text)

async def subscribe(update: Update, context: ContextTypes.DEFAULT_TYPE):
    subscribe_text = """
🚀 ПРЕМИУМ ПОДПИСКА

Получите безлимитный доступ к боту!

Преимущества:
• ♾️ Неограниченные текстовые запросы
• ♾️ Неограниченная генерация изображений
• ⚡ Приоритетная обработка

Выберите вариант:
"""
    await update.message.reply_text(subscribe_text, reply_markup=get_subscription_keyboard())

# Обработка текстовых сообщений
async def handle_text(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    user_message = update.message.text
    
    user_data = get_user(user.id, user.username)
    limits = check_limits(user_data)
    
    if limits['text_remaining'] <= 0:
        await update.message.reply_text(
            "❌ Лимит исчерпан. Ждите завтра или /subscribe",
            reply_markup=get_subscription_keyboard()
        )
        return
    
    try:
        update_user_usage(user.id, 'text')
        
        response = client.chat.completions.create(
            model="gpt-3.5-turbo",
            messages=[{"role": "user", "content": user_message}],
            max_tokens=500
        )
        
        bot_reply = response.choices[0].message.content
        await update.message.reply_text(bot_reply)
        
    except Exception as e:
        await update.message.reply_text("❌ Ошибка. Попробуйте позже.")

# Обработка генерации изображений
async def handle_image(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    
    if not context.args:
        await update.message.reply_text("❌ Укажите описание: /image закат над морем")
        return
    
    prompt = " ".join(context.args)
    user_data = get_user(user.id, user.username)
    limits = check_limits(user_data)
    
    if limits['image_remaining'] <= 0:
        await update.message.reply_text(
            "❌ Лимит изображений исчерпан. /subscribe",
            reply_markup=get_subscription_keyboard()
        )
        return
    
    try:
        update_user_usage(user.id, 'image')
        await update.message.reply_text("🎨 Генерирую...")
        
        response = client.images.generate(
            model="dall-e-2",
            prompt=prompt,
            size="512x512",
            n=1,
        )
        
        image_url = response.data[0].url
        await update.message.reply_photo(photo=image_url)
        
    except Exception as e:
        await update.message.reply_text("❌ Ошибка генерации.")

# Обработка кнопок подписки
async def handle_subscription_button(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    if query.data == 'close':
        await query.message.delete()
        return
    
    payment_text = """
✅ Для оплаты подписки:

1. Переведите сумму на карту:
   **2200-1234-5678-9012**

2. Пришлите скриншот оплаты:
   @YourSupportBot

3. Подписка активируется в течение 5 минут!

Вопросы? Пишите: @YourSupportBot
"""
    await query.edit_message_text(payment_text)

# Главная функция
def main():
    init_db()
    application = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    
    # Обработчики команд
    application.add_handler(CommandHandler("start", start))
    application.add_handler(CommandHandler("stats", stats))
    application.add_handler(CommandHandler("subscribe", subscribe))
    application.add_handler(CommandHandler("image", handle_image))
    
    # Обработчики сообщений
    application.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_text))
    
    # Обработчики кнопок
    application.add_handler(CallbackQueryHandler(handle_subscription_button))
    
    # Запуск бота
    application.run_polling()

if __name__ == '__main__':
    main()
