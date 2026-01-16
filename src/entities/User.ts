// src/entities/User.ts
import { Entity, PrimaryGeneratedColumn, Column } from "typeorm";

@Entity()
export class User {
  @PrimaryGeneratedColumn()
  id!: number;

  @Column({
    type: "varchar",
  })
  name!: string;

  @Column({ unique: true, type: "varchar" })
  email!: string;
}
