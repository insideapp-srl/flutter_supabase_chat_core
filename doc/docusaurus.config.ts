import {themes as prismThemes} from 'prism-react-renderer';
import type {Config} from '@docusaurus/types';
import type * as Preset from '@docusaurus/preset-classic';

const config: Config = {
    title: 'Flutter Supabase Chat Core',
    tagline: 'Dinosaurs are cool',
    favicon: 'img/favicon.ico',

    // Set the production url of your site here
    url: 'https://flutter-supabase-chat-core.insideapp.it',
    // Set the /<baseUrl>/ pathname under which your site is served
    // For GitHub pages deployment, it is often '/<projectName>/'
    baseUrl: '/',

    // GitHub pages deployment config.
    // If you aren't using GitHub pages, you don't need these.
    organizationName: 'insideapp-srl', // Usually your GitHub org/user name.
    projectName: 'flutter_supabase_chat_core', // Usually your repo name.

    onBrokenLinks: 'throw',
    onBrokenMarkdownLinks: 'warn',

    // Even if you don't use internationalization, you can use this field to set
    // useful metadata like html lang. For example, if your site is Chinese, you
    // may want to replace "en" with "zh-Hans".
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
                        'https://github.com/insideapp-srl/flutter_supabase_chat_core',
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
        // Replace with your project's social card
        image: 'img/social-card.png',
        colorMode: {
            defaultMode: 'dark',
            disableSwitch: false,
            respectPrefersColorScheme: false,
        },
        navbar: {
            title: 'Flutter Supabase Chat Core',
            logo: {
                alt: 'Flyer Chat Logo',
                src: 'img/logo.svg',
            },
            items: [
                {
                    type: 'docSidebar',
                    sidebarId: 'tutorialSidebar',
                    position: 'left',
                    label: 'Tutorial',
                },
                {to: 'https://docs.flyer.chat/flutter/chat-ui/', label: 'Chat UI', position: 'left'},
                {
                    to: 'https://docs.flyer.chat/flutter/firebase/firebase-overview',
                    label: 'Firebase Core',
                    position: 'left'
                },
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
                            label: 'How use',
                            to: '/',
                        },
                    ],
                },
                {
                    title: 'Community',
                    items: [
                        {
                            label: 'Site',
                            href: 'https://www.insideapp.it/',
                        },
                        {
                            label: 'GitHub',
                            href: 'https://github.com/insideapp-srl/flutter_supabase_chat_core',
                        },
                    ],
                },
                {
                    title: 'More',
                    items: [
                        {
                            label: 'Blog',
                            to: 'https://blog.insideapp.it/',
                        },
                    ],
                },
            ],
            copyright: `Copyright © ${new Date().getFullYear()} My Project, Inc. Built with Docusaurus.`,
        },
        prism: {
            theme: prismThemes.github,
            darkTheme: prismThemes.dracula,
        },
    } satisfies Preset.ThemeConfig,
};

export default config;
