import { INTERACTIVE_ROLES } from '../../lib/interactive-roles.js';

describe('INTERACTIVE_ROLES', () => {
  test('includes visible list items used as menu controls', () => {
    expect(INTERACTIVE_ROLES).toContain('listitem');
  });

  test('continues to exclude combobox controls', () => {
    expect(INTERACTIVE_ROLES).not.toContain('combobox');
  });
});
