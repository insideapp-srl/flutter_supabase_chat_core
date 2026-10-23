import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docsSidebar: [
    {
      type: 'category',
      label: 'Introduction',
      items: [
          'introduction/supabase-overview',
          'introduction/supabase-project-configuration',
          'introduction/supabase-package-installation',
      ],
    },
    {
      type: 'category',
      label: 'Guides',
      items: [
          'guides/supabase-usage',
          'guides/supabase-realtime',
          'guides/supabase-security',
          'guides/supabase-triggers',
          'guides/supabase-views',
          'guides/supabase-indexes',
          'guides/testing',
      ],
    },
  ],

};

export default sidebars;
