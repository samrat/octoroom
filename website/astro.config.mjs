// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
	site: 'https://octoroom.dev',
	integrations: [
		starlight({
			title: 'Octoroom',
			description:
				'Build realtime AI voice and vision agents in Elixir, backed by Cloudflare Realtime SFU.',
			logo: {
				src: './src/assets/logo.svg',
				alt: 'Octoroom',
			},
			favicon: '/favicon.svg',
			customCss: ['./src/styles/custom.css'],
			head: [
				{
					tag: 'script',
					content:
						"if (localStorage.getItem('starlight-theme') === null) { localStorage.setItem('starlight-theme', 'light'); document.documentElement.dataset.theme = 'light'; }",
				},
				{
					tag: 'meta',
					attrs: { property: 'og:image', content: 'https://octoroom.dev/og.png' },
				},
				{
					tag: 'meta',
					attrs: { property: 'og:image:width', content: '1200' },
				},
				{
					tag: 'meta',
					attrs: { property: 'og:image:height', content: '630' },
				},
				{
					tag: 'meta',
					attrs: {
						property: 'og:image:alt',
						content: 'Octoroom — Build realtime AI voice agents in Elixir with Cloudflare Realtime SFU',
					},
				},
				{
					tag: 'meta',
					attrs: { name: 'twitter:card', content: 'summary_large_image' },
				},
				{
					tag: 'meta',
					attrs: { name: 'twitter:image', content: 'https://octoroom.dev/og.png' },
				},
			],
			editLink: {
				baseUrl: 'https://github.com/samrat/octoroom/edit/main/website/',
			},
			social: [
				{
					icon: 'github',
					label: 'GitHub',
					href: 'https://github.com/samrat/octoroom',
				},
			],
			expressiveCode: {
				themes: ['github-light', 'github-dark'],
				styleOverrides: {
					borderRadius: '0.625rem',
					borderColor: 'var(--sl-color-hairline)',
				},
			},
			sidebar: [
				{
					label: 'Start Here',
					items: [
						{ label: 'Overview', slug: 'docs' },
						{ label: 'Getting Started', slug: 'docs/getting-started' },
						{ label: 'Architecture', slug: 'docs/architecture' },
					],
				},
				{
					label: 'Core Guides',
					items: [
						{ label: 'Rooms & Routing Policies', slug: 'docs/guides/rooms' },
						{ label: 'Server-Side Workers', slug: 'docs/guides/workers' },
						{ label: 'AI Voice & Vision Agents', slug: 'docs/guides/agents' },
					],
				},
				{
					label: 'Clients',
					items: [
						{ label: 'Browser Client (JS)', slug: 'docs/clients/browser' },
						{ label: 'Swift SDK (iOS & macOS)', slug: 'docs/clients/swift' },
					],
				},
				{
					label: 'Resources',
					items: [
						{ label: 'Examples', slug: 'docs/examples' },
						{
							label: 'HexDocs — octoroom',
							link: 'https://hexdocs.pm/octoroom',
							attrs: { target: '_blank', rel: 'noopener noreferrer' },
						},
						{
							label: 'HexDocs — octoroom_agents',
							link: 'https://hexdocs.pm/octoroom_agents',
							attrs: { target: '_blank', rel: 'noopener noreferrer' },
						},
					],
				},
			],
		}),
	],
});
