#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

int main(void) {
  GhosttyOscParser parser;
  if (ghostty_osc_new(NULL, &parser) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "ghostty_osc_new failed\n");
    return 1;
  }

  const char *payload = "133;C;ZXhwb3J0";
  for (size_t i = 0; i < strlen(payload); i++) {
    ghostty_osc_next(parser, payload[i]);
  }

  GhosttyOscCommand command = ghostty_osc_end(parser, 0);
  GhosttyOscCommandType type = ghostty_osc_command_type(command);
  ghostty_osc_free(parser);

  printf("libghostty-vt osc command type: %d\n", type);
  return 0;
}
