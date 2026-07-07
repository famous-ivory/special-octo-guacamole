import { Bot } from 'grammy';
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
    const args = text.split(' ').slice(1).join(' ');

    if (!args) {
      return ctx.reply('Please provide a Magnet Link or URL to a .torrent file. Example: `/download magnet:?xt=urn:btih:...`', { parse_mode: 'Markdown' });
    }

    await ctx.reply('Triggering GitHub Actions...');

    try {
      const success = await triggerWorkflow(env, args);
      if (success) {
        await ctx.reply('Download request sent successfully. You can use /status to check the progress.');
      } else {
        await ctx.reply('Error calling GitHub API. Please check your GITHUB_TOKEN or repository access.');
      }
    } catch (e: any) {
      await ctx.reply(`System error: ${e.message}`);
    }
  });

  bot.command('status', async (ctx) => {
    try {
      const run = await getLatestRunStatus(env);
      if (!run) {
        return ctx.reply('No workflow run found. Please make sure the workflow "torrent.yml" has been executed.');
      }

      const status = (run.status || '').replace(/_/g, '\\_');
      const conclusion = (run.conclusion || '').replace(/_/g, '\\_');
      const url = run.html_url;

      let msg = `*Latest Run Status:*\n`;
      msg += `- Status: ${status}\n`;
      if (conclusion) msg += `- Conclusion: ${conclusion}\n`;
      msg += `[View details on GitHub](${url})`;

      await ctx.reply(msg, { parse_mode: 'Markdown', disable_web_page_preview: true });
    } catch (e: any) {
      await ctx.reply(`Error getting status: ${e.message}`);
    }
  });

  return bot;
}
