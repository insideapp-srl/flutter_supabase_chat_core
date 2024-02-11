"use strict";(self.webpackChunkflutter_supabase_chat_core=self.webpackChunkflutter_supabase_chat_core||[]).push([[428],{8692:(e,s,t)=>{t.r(s),t.d(s,{assets:()=>c,contentTitle:()=>i,default:()=>g,frontMatter:()=>a,metadata:()=>o,toc:()=>u});var n=t(7624),r=t(2172);const a={id:"supabase-triggers",title:"Database Triggers"},i=void 0,o={id:"guides/supabase-triggers",title:"Database Triggers",description:"This is an example of a triggers that sets room's lastMessages to the most recent message sent once recieved in Firestore.",source:"@site/docs/guides/supabse-trigges.md",sourceDirName:"guides",slug:"/guides/supabase-triggers",permalink:"/guides/supabase-triggers",draft:!1,unlisted:!1,editUrl:"https://github.com/insideapp-srl/flutter_supabase_chat_core/docs/guides/supabse-trigges.md",tags:[],version:"current",frontMatter:{id:"supabase-triggers",title:"Database Triggers"},sidebar:"tutorialSidebar",previous:{title:"Security Rules",permalink:"/guides/supabase-security"}},c={},u=[];function d(e){const s={code:"code",p:"p",pre:"pre",...(0,r.M)(),...e.components};return(0,n.jsxs)(n.Fragment,{children:[(0,n.jsxs)(s.p,{children:["This is an example of a triggers that sets room's ",(0,n.jsx)(s.code,{children:"lastMessages"})," to the most recent message sent once recieved in Firestore."]}),"\n",(0,n.jsx)(s.pre,{children:(0,n.jsx)(s.code,{className:"language-sql",children:'    CREATE OR REPLACE FUNCTION chats.update_last_messages()\n        RETURNS TRIGGER AS $$\n    DECLARE\n    ts_in_milliseconds bigint;\n    BEGIN\n    SELECT EXTRACT(epoch FROM NOW()) * 1000 INTO ts_in_milliseconds;\n    UPDATE chats.rooms\n    SET "updatedAt" = ts_in_milliseconds,\n        "lastMessages" = jsonb_build_array(NEW)\n    WHERE id = NEW."roomId";\n    RETURN NEW;\n    END;\n    $$ LANGUAGE plpgsql;\n    \n    CREATE TRIGGER update_last_messages_trigger\n        AFTER INSERT ON chats.messages\n        FOR EACH ROW\n    EXECUTE FUNCTION chats.update_last_messages();\n'})})]})}function g(e={}){const{wrapper:s}={...(0,r.M)(),...e.components};return s?(0,n.jsx)(s,{...e,children:(0,n.jsx)(d,{...e})}):d(e)}},2172:(e,s,t)=>{t.d(s,{I:()=>o,M:()=>i});var n=t(1504);const r={},a=n.createContext(r);function i(e){const s=n.useContext(a);return n.useMemo((function(){return"function"==typeof e?e(s):{...s,...e}}),[s,e])}function o(e){let s;return s=e.disableParentContext?"function"==typeof e.components?e.components(r):e.components||r:i(e.components),n.createElement(a.Provider,{value:s},e.children)}}}]);