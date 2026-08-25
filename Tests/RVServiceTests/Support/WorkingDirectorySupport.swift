import RVDomain

func wd(_ raw: String) -> WorkingDirectory {
    WorkingDirectory(validating: raw)!
}
