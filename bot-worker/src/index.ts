import { Hono } from 'hono';
import { webhookCallback } from 'grammy';
import { Bindings } from './types';
import { setupBot } from './bot';

const app = new Hono<{ Bindings: Bindings }>();

app.get('/', (c) => c.text('Telegram Bot Worker is running'));

// Endpoint to receive messages from Telegram
app.post('/webhook', async (c) => {
  try {
    const bot = setupBot(c.env);

    // Update command menu (running once is enough, but called here for convenience.
    // In practice, this can be optimized by calling separately via another script).
    await bot.api.setMyCommands([
      { command: 'help', description: 'Show guide' },
      { command: 'ping', description: 'Check bot status' },
      { command: 'download', description: 'Download new torrent' },
      { command: 'status', description: 'Check download status' },
    ]);

    // Use grammY's webhookCallback helper for Hono
    const handle = webhookCallback(bot, 'hono');
    return await handle(c);
  } catch (e: any) {
    console.error('Webhook error:', e);
    return c.json({ ok: false, error: e.message });
  }
});


// Webhook endpoint simulating Discord to receive notifications from GitHub Actions
app.post('/callback', async (c) => {
  try {
    const body = await c.req.json();
    
    // Script notify_discord.ps1 sends payload with structure:
    // { embeds: [ { title: "...", description: "...", color: 65280 } ] }
    if (body && body.embeds && body.embeds.length > 0) {
      const embed = body.embeds[0];
      const title = (embed.title || 'Notification').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      let description = (embed.description || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
      
      // Convert Markdown bold to HTML bold because parse_mode is HTML
      description = description.replace(/\*\*(.*?)\*\*/g, '<b>$1</b>');
      
      let message = `<b>${title}</b>\n\n${description}`;
      
      const bot = setupBot(c.env);
      const adminChatId = c.env.ADMIN_CHAT_ID;
      
      if (adminChatId) {
        if (body.chat_id && body.message_id) {
          try {
            await bot.api.editMessageText(body.chat_id, body.message_id, message, {
              parse_mode: 'HTML',
              link_preview_options: { is_disabled: true }
            });
          } catch (editError: any) {
             console.error('Failed to edit message, sending new one', editError);
             if (editError.message && !editError.message.includes('message is not modified')) {
                 await bot.api.sendMessage(adminChatId, message, {
                   parse_mode: 'HTML',
                   link_preview_options: { is_disabled: true }
                 });
             }
          }
        } else {
          await bot.api.sendMessage(adminChatId, message, {
            parse_mode: 'HTML',
            link_preview_options: { is_disabled: true }
          });
        }
      }
    }
    
    return c.json({ ok: true });
  } catch (e: any) {
    console.error('Callback error:', e);
    return c.json({ ok: false, error: e.message });
  }
});

export default app;
