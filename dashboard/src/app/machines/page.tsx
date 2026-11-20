import { Suspense } from "react"
import { DownloadIcon } from "lucide-react"
import { Button } from "@/components/ui/button"
import { PageBody, PageHeader } from "@/components/shared"
import { MachinesTable } from "./machines-table"

export default function MachinesPage() {
  return (
    <>
      <PageHeader
        title="Machines"
        description="Every enrolled machine, from its latest rv report."
        actions={
          <Button variant="outline">
            <DownloadIcon />
            Export CSV
          </Button>
        }
      />
      <PageBody>
        <Suspense>
          <MachinesTable />
        </Suspense>
      </PageBody>
    </>
  )
}
