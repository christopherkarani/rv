"use client";

import { useTheme } from "next-themes";
import { Moon, Sun } from "lucide-react";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

/** Dark is the default (light under the rykan theme); one click flips to light and back. The icon is chosen in CSS, so it never flashes. */
export function ThemeToggle() {
  const { resolvedTheme, setTheme } = useTheme();
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-label="Switch between light and dark theme"
          onClick={() => setTheme(resolvedTheme === "dark" ? "light" : "dark")}
          className="grid size-7 place-items-center rounded-md text-muted-foreground transition-colors hover:bg-hover hover:text-foreground"
        >
          <Sun className="size-4 transition-transform duration-300 dark:hidden" strokeWidth={1.75} />
          <Moon className="hidden size-4 transition-transform duration-300 dark:block" strokeWidth={1.75} />
        </button>
      </TooltipTrigger>
      <TooltipContent>Light / dark</TooltipContent>
    </Tooltip>
  );
}
