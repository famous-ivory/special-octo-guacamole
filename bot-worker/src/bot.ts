import { Bot, InlineKeyboard } from 'grammy';
import { Bindings } from './types';
import { triggerWorkflow, getLatestRunStatus } from './github';

export function setupBot(env: Bindings) {
  const bot = new Bot(env.BOT_TOKEN);

  // Restrict bot usage to the ADMIN_CHAT_ID
  bot.use(async (ctx, next) => {
    const chatId = ctx.chat?.id.toString();
    if (env.ADMIN_CHAT_ID && chatId !== env.ADMIN_CHAT_ID) {
      await ctx.reply('You are not authorized to use this bot.');
      return;
    }
    await next();
  });

  bot.command('start', (ctx) => {
    return ctx.reply('Hello. I am a bot that helps download Torrents and upload them to Gofile. Type /help to see the command list.');
  });

  bot.command('help', (ctx) => {
    const helpText = `
*Command List:*
/help - Show this guide
/ping - Check bot connection
/download <magnet-link or URL> - Trigger torrent download
/status - View the latest GitHub Action status
    `;
    return ctx.reply(helpText, { parse_mode: 'Markdown' });
  });

  bot.command('ping', (ctx) => {
    return ctx.reply('Pong. The bot is working normally on Cloudflare Workers.');
  });

  bot.command('download', async (ctx) => {
    const text = ctx.message?.text || '';
    const args = text.split(' ').slice(1).join(' ').trim();

    if (!args) {
      return ctx.reply('Please provide a Magnet Link or URL to a .torrent file.\nExample: `/download magnet:?xt=urn:btih:...`', { parse_mode: 'Markdown' });
    }

    const keyboard = new InlineKeyboard()
      .text('Yes (Zip)', 'dl_zip')
      .text('No (Raw)', 'dl_raw');

    await ctx.reply(`Do you want to compress this download into a zip archive?\n\nLink:\n${args}`, {
      reply_markup: keyboard,
      link_preview_options: { is_disabled: true }
    });
  });

  bot.on('callback_query:data', async (ctx) => {
    const data = ctx.callbackQuery.data;
    
    if (data === 'dl_zip' || data === 'dl_raw') {
      const compress = data === 'dl_zip' ? 'true' : 'false';
      
      const msgText = ctx.callbackQuery.message?.text || '';
      const parts = msgText.split('\nLink:\n');
      if (parts.length < 2) {
         await ctx.answerCallbackQuery({ text: 'Error: Could not extract link from message.', show_alert: true });
         return;
      }
      const link = parts[1].trim();

      const msg = await ctx.editMessageText(`Triggering GitHub Actions... (Compress: ${compress === 'true' ? 'Yes' : 'No'})\n\nLink:\n${link}`, { link_preview_options: { is_disabled: true } });
      
      const chatId = ctx.chat?.id.toString();
      const messageId = typeof msg === 'boolean' ? undefined : msg.message_id.toString();

      try {
        const success = await triggerWorkflow(env, link, compress, messageId);
        if (success) {
          await ctx.editMessageText(`Download request sent successfully.\nCompress: ${compress === 'true' ? 'Yes' : 'No'}\n\nYou can use /status to check the progress.`, { link_preview_options: { is_disabled: true } });
        } else {
          await ctx.editMessageText('Error calling GitHub API. Please check your GH_TOKEN or repository access.');
        }
      } catch (e: any) {
        await ctx.editMessageText(`System error: ${e.message}`);
      }
      
      await ctx.answerCallbackQuery();
    }
  });

  bot.command('status', async (ctx) => {
    try {
      const run = await getLatestRunStatus(env);
      if (!run) {
        return ctx.reply('No workflow run found. Please make sure the workflow "torrent-to-gofile.yml" has been executed.');
      }

      const status = (run.status || '').replace(/_/g, '\\_');
      const conclusion = (run.conclusion || '').replace(/_/g, '\\_');
      const url = run.html_url;

      let msg = `*Latest Run Status:*\n`;
      msg += `- Status: ${status}\n`;
      if (conclusion) msg += `- Conclusion: ${conclusion}\n`;
      msg += `[View details on GitHub](${url})`;

      await ctx.reply(msg, { parse_mode: 'Markdown', link_preview_options: { is_disabled: true } });
    } catch (e: any) {
      await ctx.reply(`Error getting status: ${e.message}`);
    }
  });

  return bot;
}
