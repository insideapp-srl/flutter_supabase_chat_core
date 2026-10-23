import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
    title: 'Flutter Supabase Chat Core',
    tagline: 'Real-time chat for Flutter on Supabase',
    favicon: 'img/favicon.ico',

    url: 'https://flutter-supabase-chat-core.insideapp.it',
    baseUrl: '/',

    organizationName: 'insideapp-srl',
    projectName: 'flutter_supabase_chat_core',

    onBrokenLinks: 'throw',
    onBrokenMarkdownLinks: 'warn',

    headTags: [
        {
            tagName: 'link',
            attributes: {
                rel: 'apple-touch-icon',
                sizes: '180x180',
                href: '/img/apple-touch-icon.png',
            },
        },
    ],

    i18n: {
        defaultLocale: 'en',
        locales: ['en'],
    },
    presets: [
        [
            'classic',
            {
                docs: {
                    sidebarPath: './sidebars.ts',
                    editUrl:
                        'https://github.com/insideapp-srl/flutter_supabase_chat_core/tree/main/doc/',
                    routeBasePath: '/',
                },

                theme: {
                    customCss: './src/css/custom.css',
                },
                blog: false,
            } satisfies Preset.Options,
        ],
    ],

    themeConfig: {
        // Link preview image (example app screenshot).
        image: 'img/social-card.png',
        colorMode: {
            defaultMode: 'dark',
            disableSwitch: false,
            respectPrefersColorScheme: false,
        },
        navbar: {
            title: 'Supabase Chat Core',
            logo: {
                alt: 'Flyer Chat Logo',
                src: 'img/flyer-chat-logo-dark.svg',
                srcDark: 'img/flyer-chat-logo-light.svg',
            },
            items: [
                {
                    type: 'docSidebar',
                    sidebarId: 'docsSidebar',
                    position: 'left',
                    label: 'Docs',
                },
                {to: 'https://flyer.chat/docs/flutter/introduction/', label: 'Chat UI', position: 'left'},
                {
                    href: 'https://github.com/insideapp-srl/flutter_supabase_chat_core',
                    label: 'GitHub',
                    position: 'right',
                },
            ],
        },
        footer: {
            style: 'dark',
            links: [
                {
                    title: 'Docs',
                    items: [
                        {
                            label: 'Getting started',
                            to: '/',
                        },
                    ],
                },
                {
                    title: 'Community',
                    items: [
                        {
                            label: 'InsideApp',
                            href: 'https://www.insideapp.it/',
                        },
                        {
                            label: 'GitHub',
                            href: 'https://github.com/insideapp-srl/flutter_supabase_chat_core',
                        },
                    ],
                },
            ],
            copyright: `Copyright © ${new Date().getFullYear()} InsideApp S.r.l. Built with Docusaurus.`,
        },
        prism: {
            theme: prismThemes.github,
            darkTheme: prismThemes.dracula,
        },
    } satisfies Preset.ThemeConfig,
};

export default config;
