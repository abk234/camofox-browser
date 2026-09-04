/**
 * ARIA roles that represent controls an agent may meaningfully interact with.
 * List items are included because many menu implementations attach their action
 * directly to a visible `li` rather than exposing a nested menuitem or link.
 */
export const INTERACTIVE_ROLES = Object.freeze([
  'button', 'link', 'textbox', 'checkbox', 'radio',
  'menuitem', 'listitem', 'tab', 'searchbox', 'slider', 'spinbutton', 'switch',
]);
