import { Bindings } from './types';

export async function triggerWorkflow(env: Bindings, torrentLink: string): Promise<boolean> {
  const url = `https://api.github.com/repos/${env.GH_OWNER}/${env.GH_REPO}/actions/workflows/torrent-to-gofile.yml/dispatches`;

  const payload = {
    ref: "main",
    inputs: {
      torrent_link: torrentLink,
      compress_before_upload: "false",
      max_concurrent_uploads: "5"
    }
  };

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "Accept": "application/vnd.github.v3+json",
      "Authorization": `Bearer ${env.GH_TOKEN}`,
      "User-Agent": "Telegram-Cloudflare-Worker"
    },
    body: JSON.stringify(payload)
  });

  if (!response.ok) {
    const errorText = await response.text();
    console.error(`GitHub API workflow dispatch failed with status ${response.status}: ${errorText}`);
  }

  return response.ok || response.status === 204;
}

export async function getLatestRunStatus(env: Bindings): Promise<any> {
  // Get the list of workflow runs for torrent.yml
  const url = `https://api.github.com/repos/${env.GH_OWNER}/${env.GH_REPO}/actions/workflows/torrent.yml/runs?per_page=1`;

  const response = await fetch(url, {
    method: "GET",
    headers: {
      "Accept": "application/vnd.github.v3+json",
      "Authorization": `Bearer ${env.GH_TOKEN}`,
      "User-Agent": "Telegram-Cloudflare-Worker"
    }
  });

  if (!response.ok) {
    return null;
  }

  const data: any = await response.json();
  if (data.workflow_runs && data.workflow_runs.length > 0) {
    return data.workflow_runs[0];
  }
  return null;
}
